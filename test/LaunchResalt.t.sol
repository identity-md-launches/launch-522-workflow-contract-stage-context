// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PvPadFactory} from "../src/PvPadFactory.sol";
import {PvPadToken} from "../src/PvPadToken.sol";
import {PvPadHook, IPvPadLaunchRegistry} from "../src/hooks/PvPadHook.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

contract FactoryDeployer {
    function deploy(PoolManager manager, WorkerSubsidy workers, KingOfThePad king, PvPadHook hook, address creator)
        external
        returns (PvPadFactory)
    {
        return new PvPadFactory(manager, workers, king, hook, creator);
    }
}

/// @dev Proofs for bounded salt retry when a predicted pool is preinitialized at a foreign price (LOW).
contract LaunchResaltTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    WorkerSubsidy internal workers;
    KingOfThePad internal king;
    PvPadHook internal hook;
    PvPadFactory internal factory;
    address internal creator = address(0xC0FFEE);
    uint256 internal constant FEE = 0.0005 ether;
    uint160 internal constant POISON = uint160(1) << 96;

    event LaunchSaltRetried(uint256 indexed launchId, uint256 attempt, address token);

    function setUp() public {
        manager = new PoolManager(address(this));
        workers = new WorkerSubsidy(address(this));
        king = new KingOfThePad(workers);
        (, bytes32 salt) = HookMiner.findPvPadHook(address(this), address(manager));
        hook = new PvPadHook{salt: salt}(manager);
        factory = new PvPadFactory(manager, workers, king, hook, creator);
        vm.deal(creator, 100 ether);
    }

    function test_poisonedPredictedPoolSkipsToNextSaltAndNeverSeedsForeignPrice() public {
        address first = _token(address(factory), 1, creator, "Poisoned", "PSN", 0, 0);
        address second = _token(address(factory), 1, creator, "Poisoned", "PSN", 0, 1);
        manager.initialize(_key(first), POISON);
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Poisoned", "PSN", 0);
        assertEq(predicted, second);
        assertEq(attempt, 1);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchSaltRetried(1, 1, second);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Poisoned", "PSN");
        assertEq(id, 1);
        (, address token, address curve,, PoolId poolId) = factory.launches(id);
        assertEq(token, second);
        assertEq(first.code.length, 0);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(_key(second).toId()));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
        assertEq(workers.workerPot(), FEE);

        // The poisoned pool is untouched: still at the attacker's price, unbound, unfunded.
        (uint160 poisonedPrice,,,) = StateLibrary.getSlot0(manager, _key(first).toId());
        assertEq(poisonedPrice, POISON);
        assertEq(StateLibrary.getLiquidity(manager, _key(first).toId()), 0);
        (IPvPadLaunchRegistry registry,,) = hook.bindings(_key(first).toId());
        assertEq(address(registry), address(0));
        assertFalse(factory.registeredPool(_key(first).toId()));
    }

    function test_canonicalPreinitializationKeepsAttemptZero() public {
        address first = _token(address(factory), 1, creator, "Canonical", "CAN", 0, 0);
        manager.initialize(_key(first), factory.canonicalSqrtPriceX96());
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Canonical", "CAN", 0);
        assertEq(predicted, first);
        assertEq(attempt, 0);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Canonical", "CAN");
        (, address token,,,) = factory.launches(id);
        assertEq(token, first);
    }

    function test_repeatedFrontRunningConsumesSuccessiveAttempts() public {
        for (uint256 i; i < 3; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Chase", "CHS", 0, i)), POISON);
        }
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Chase", "CHS", 0);
        assertEq(attempt, 3);
        assertEq(predicted, _token(address(factory), 1, creator, "Chase", "CHS", 0, 3));
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Chase", "CHS");
        (, address token,,,) = factory.launches(id);
        assertEq(token, predicted);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_poisonDepthWithinBoundSelectsFirstCleanSalt(uint8 depthSeed, bytes32 userSalt) public {
        uint256 depth = bound(depthSeed, 0, factory.MAX_SALT_ATTEMPTS() - 1);
        for (uint256 i; i < depth; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Fuzz", "FZ", userSalt, i)), POISON);
        }
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Fuzz", "FZ", userSalt);
        assertEq(attempt, depth);
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Fuzz", "FZ", userSalt);
        (, address token,,, PoolId poolId) = factory.launches(id);
        assertEq(token, predicted);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
    }

    function test_everyBoundedSaltPoisonedFailsClosedWithoutCharging() public {
        uint256 attempts = factory.MAX_SALT_ATTEMPTS();
        for (uint256 i; i < attempts; ++i) {
            manager.initialize(_key(_token(address(factory), 1, creator, "Brick", "BRK", 0, i)), POISON);
        }
        vm.expectRevert(PvPadFactory.UnexpectedPoolPrice.selector);
        factory.predictLaunchToken(creator, "Brick", "BRK", 0);
        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        vm.expectRevert(PvPadFactory.UnexpectedPoolPrice.selector);
        factory.createLaunch{value: FEE}("Brick", "BRK");
        assertEq(factory.launchCount(), 1);
        assertEq(creator.balance, balanceBefore);
        assertEq(workers.workerPot(), 0);
        for (uint256 i; i < attempts; ++i) {
            assertEq(_token(address(factory), 1, creator, "Brick", "BRK", 0, i).code.length, 0);
        }
        // A fresh user salt or any other input moves to an unpoisoned derivation.
        vm.prank(creator);
        uint256 id = factory.createLaunch{value: FEE}("Brick", "BRK", bytes32(uint256(1)));
        assertEq(id, 1);
        (, address token,,, PoolId poolId) = factory.launches(id);
        assertEq(token, _token(address(factory), 1, creator, "Brick", "BRK", bytes32(uint256(1)), 0));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, factory.canonicalSqrtPriceX96());
    }

    function test_poisonedGenesisPoolResaltsInsideConstructor() public {
        // A fresh deployer contract has nonce 1, so its first CREATE address is exactly predictable.
        FactoryDeployer deployer = new FactoryDeployer();
        address futureFactory = vm.computeCreateAddress(address(deployer), 1);
        address first = _token(futureFactory, 0, creator, "Pepe Values Pepe", "PVP", 0, 0);
        address second = _token(futureFactory, 0, creator, "Pepe Values Pepe", "PVP", 0, 1);
        manager.initialize(_key(first), POISON);
        vm.expectEmit(true, true, true, true, futureFactory);
        emit LaunchSaltRetried(0, 1, second);
        PvPadFactory resalted = deployer.deploy(manager, workers, king, hook, creator);
        assertEq(address(resalted), futureFactory);
        (, address token, address curve,, PoolId poolId) = resalted.launches(0);
        assertEq(token, second);
        assertEq(first.code.length, 0);
        assertEq(PvPadToken(token).balanceOf(curve), 1e27);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(price, resalted.canonicalSqrtPriceX96());
        (uint160 poisonedPrice,,,) = StateLibrary.getSlot0(manager, _key(first).toId());
        assertEq(poisonedPrice, POISON);
    }

    function test_predictionMatchesUnpoisonedCreateAndAdvancesWithLaunchCount() public {
        (address predicted, uint256 attempt) = factory.predictLaunchToken(creator, "Plain", "PLN", 0);
        assertEq(attempt, 0);
        assertEq(predicted, _token(address(factory), 1, creator, "Plain", "PLN", 0, 0));
        vm.prank(creator);
        factory.createLaunch{value: FEE}("Plain", "PLN");
        (, address token,,,) = factory.launches(1);
        assertEq(token, predicted);
        (address next,) = factory.predictLaunchToken(creator, "Plain", "PLN", 0);
        assertTrue(next != predicted);
        assertEq(next, _token(address(factory), 2, creator, "Plain", "PLN", 0, 0));
    }

    function _token(
        address deployer,
        uint256 launchId,
        address launchCreator,
        string memory name,
        string memory symbol,
        bytes32 userSalt,
        uint256 attempt
    ) internal pure returns (address) {
        bytes32 salt = attempt == 0
            ? keccak256(abi.encode(launchId, launchCreator, name, symbol, userSalt))
            : keccak256(abi.encode(launchId, launchCreator, name, symbol, userSalt, attempt));
        bytes32 initHash = keccak256(abi.encodePacked(type(PvPadToken).creationCode, abi.encode(name, symbol)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 60, IHooks(address(hook)));
    }
}
