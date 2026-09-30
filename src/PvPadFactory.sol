// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PvPadToken} from "./PvPadToken.sol";
import {BondingCurve, IPvPadFactoryCurve} from "./BondingCurve.sol";
import {FeeEscrow} from "./FeeEscrow.sol";
import {KingOfThePad} from "./KingOfThePad.sol";
import {WorkerSubsidy} from "./WorkerSubsidy.sol";
import {PvPadHook} from "./hooks/PvPadHook.sol";
import {PvPadConstants} from "./libraries/PvPadConstants.sol";

/// @notice Permissionless pad: creates curves and permanently holds their graduated full-range positions.
/// @dev The factory owns v4 positions. There is no call path that decreases liquidity or collects it.
contract PvPadFactory is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    error LaunchFeeRequired();
    error UnknownLaunch();
    error NotReady();
    error AlreadyGraduated();
    error ZeroAddress();
    error InvalidConfiguration();
    error InvalidMetadata();
    error UnexpectedPoolPrice();
    error InvalidCallback();
    error ZeroLiquidity();

    event LaunchCreated(
        uint256 indexed launchId, address indexed creator, address token, address curve, string name, string symbol
    );
    event Graduated(uint256 indexed launchId, PoolId poolId, uint160 sqrtPriceX96);
    event LaunchMetadata(uint256 indexed launchId, string metadataURI);
    event LiquidityLocked(uint256 indexed launchId, uint128 liquidity, uint256 ethDust, uint256 tokenDust);

    struct Launch {
        address creator;
        address token;
        address curve;
        bool graduated;
        PoolId poolId;
    }

    IPoolManager public immutable poolManager;
    WorkerSubsidy public immutable workerSubsidy;
    KingOfThePad public immutable kingOfThePad;
    FeeEscrow public immutable feeEscrow;
    PvPadHook public immutable hook;
    uint160 public immutable canonicalSqrtPriceX96;
    uint256 public constant launchFee = PvPadConstants.DEFAULT_LAUNCH_FEE;
    uint256 public constant graduationThreshold = PvPadConstants.GRADUATION_THRESHOLD;
    uint256 public launchCount;

    mapping(uint256 => Launch) public launches;
    mapping(uint256 => string) public launchMetadataURI;
    mapping(PoolId => bool) public registeredPool;
    mapping(PoolId => address) public poolCreator;
    mapping(address => bool) public isBondingCurve;
    mapping(uint256 => uint128) public lockedLiquidity;
    bytes32 private expectedCallback;

    constructor(
        IPoolManager _poolManager,
        WorkerSubsidy _workerSubsidy,
        KingOfThePad _king,
        PvPadHook _hook,
        address genesisCreator
    ) {
        if (
            address(_poolManager) == address(0) || address(_workerSubsidy) == address(0) || address(_king) == address(0)
                || address(_hook) == address(0) || genesisCreator == address(0)
        ) revert ZeroAddress();
        if (
            address(_hook.poolManager()) != address(_poolManager)
                || address(_king.workerSubsidy()) != address(_workerSubsidy)
        ) revert InvalidConfiguration();
        poolManager = _poolManager;
        workerSubsidy = _workerSubsidy;
        kingOfThePad = _king;
        hook = _hook;
        feeEscrow = new FeeEscrow(_king, address(this));
        feeEscrow.authorizeRecorder(address(_hook), true);
        // FullMath avoids truncating amount1 << 192 before division.
        canonicalSqrtPriceX96 = uint160(
            Math.sqrt(FullMath.mulDiv(PvPadConstants.TOKEN_SUPPLY / 4, uint256(1) << 192, graduationThreshold))
        );
        _createLaunch(genesisCreator, "Pepe Values Pepe", "PVP", bytes32(0));
        emit LaunchMetadata(0, "");
    }

    /// @notice True only once this factory has funded and locked the pool.
    function isRegisteredPool(PoolId poolId) external view returns (bool) {
        return registeredPool[poolId];
    }

    function launchCreator(PoolId poolId) external view returns (address) {
        return poolCreator[poolId];
    }

    function createLaunch(string calldata name, string calldata symbol)
        external
        payable
        nonReentrant
        returns (uint256 launchId)
    {
        return _paidLaunch(name, symbol, bytes32(0), "");
    }

    /// @notice Salt permits choosing a fresh token/pool address if someone preinitialized a predicted address.
    function createLaunch(string calldata name, string calldata symbol, bytes32 salt)
        external
        payable
        nonReentrant
        returns (uint256 launchId)
    {
        return _paidLaunch(name, symbol, salt, "");
    }

    /// @notice Optional immutable URI for an off-chain image, description and social links document.
    function createLaunch(string calldata name, string calldata symbol, bytes32 salt, string calldata metadataURI)
        external
        payable
        nonReentrant
        returns (uint256 launchId)
    {
        return _paidLaunch(name, symbol, salt, metadataURI);
    }

    function _paidLaunch(string memory name, string memory symbol, bytes32 salt, string memory metadataURI)
        private
        returns (uint256 launchId)
    {
        if (msg.value != launchFee) revert LaunchFeeRequired();
        if (bytes(metadataURI).length > 2048) revert InvalidMetadata();
        launchId = _createLaunch(msg.sender, name, symbol, salt);
        launchMetadataURI[launchId] = metadataURI;
        emit LaunchMetadata(launchId, metadataURI);
        workerSubsidy.fundWorkers{value: msg.value}();
    }

    function _createLaunch(address creator, string memory name, string memory symbol, bytes32 userSalt)
        internal
        returns (uint256 launchId)
    {
        if (
            bytes(name).length == 0 || bytes(name).length > 64 || bytes(symbol).length == 0 || bytes(symbol).length > 16
        ) {
            revert InvalidMetadata();
        }
        launchId = launchCount++;
        bytes32 salt = keccak256(abi.encode(launchId, creator, name, symbol, userSalt));
        PvPadToken token = new PvPadToken{salt: salt}(name, symbol);
        BondingCurve curve = new BondingCurve(
            IERC20(address(token)), IPvPadFactoryCurve(address(this)), launchId, creator, feeEscrow, kingOfThePad
        );
        PoolKey memory key = _poolKey(address(token));
        PoolId poolId = key.toId();
        launches[launchId] = Launch(creator, address(token), address(curve), false, poolId);
        isBondingCurve[address(curve)] = true;
        poolCreator[poolId] = creator;
        feeEscrow.authorizeRecorder(address(curve), true);
        hook.bindPool(key, creator, feeEscrow);
        (uint160 existingPrice,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (existingPrice == 0) {
            poolManager.initialize(key, canonicalSqrtPriceX96);
        } else if (existingPrice != canonicalSqrtPriceX96) {
            // Reject poisoned price before any trader can fund this curve.
            revert UnexpectedPoolPrice();
        }
        IERC20(address(token)).safeTransfer(address(curve), PvPadConstants.TOKEN_SUPPLY);
        emit LaunchCreated(launchId, creator, address(token), address(curve), name, symbol);
    }

    function getPoolKey(uint256 launchId) external view returns (PoolKey memory) {
        if (launches[launchId].token == address(0)) revert UnknownLaunch();
        return _poolKey(launches[launchId].token);
    }

    function _poolKey(address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: PvPadConstants.POOL_FEE,
            tickSpacing: PvPadConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function graduate(uint256 launchId) external nonReentrant returns (PoolId poolId) {
        Launch storage launch = launches[launchId];
        if (launch.curve == address(0)) revert UnknownLaunch();
        if (launch.graduated) revert AlreadyGraduated();
        BondingCurve curve = BondingCurve(payable(launch.curve));
        if (!curve.readyToGraduate()) revert NotReady();
        poolId = launch.poolId;
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (price != canonicalSqrtPriceX96) revert UnexpectedPoolPrice();
        (uint256 ethAmount, uint256 tokenAmount) = curve.sweepForGraduation();
        launch.graduated = true;
        bytes memory data = abi.encode(_poolKey(launch.token), ethAmount, tokenAmount, launchId);
        expectedCallback = keccak256(data);
        poolManager.unlock(data);
        if (expectedCallback != bytes32(0)) revert InvalidCallback();
        registeredPool[poolId] = true;
        emit Graduated(launchId, poolId, price);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || expectedCallback == bytes32(0)
                || keccak256(rawData) != expectedCallback
        ) revert InvalidCallback();
        expectedCallback = bytes32(0);
        (PoolKey memory key, uint256 ethAmount, uint256 tokenAmount, uint256 launchId) =
            abi.decode(rawData, (PoolKey, uint256, uint256, uint256));
        int24 tickLower = TickMath.minUsableTick(PvPadConstants.POOL_TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(PvPadConstants.POOL_TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            canonicalSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            tokenAmount
        );
        if (liquidity == 0) revert ZeroLiquidity();
        lockedLiquidity[launchId] = liquidity;
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(launchId)
        });
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        uint256 usedEth = uint256(uint128(-delta.amount0()));
        uint256 usedToken = uint256(uint128(-delta.amount1()));
        key.currency0.settle(poolManager, address(this), usedEth, false);
        key.currency1.settle(poolManager, address(this), usedToken, false);
        // Integer rounding dust remains locked at this contract, with no recovery or withdrawal path.
        emit LiquidityLocked(launchId, liquidity, ethAmount - usedEth, tokenAmount - usedToken);
        return "";
    }

    receive() external payable {}
}
