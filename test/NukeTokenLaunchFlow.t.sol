// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NukeToken} from "../src/NukeToken.sol";

/// @notice Simulates the launch's token flows without the pool: a factory-like contract deploys
///         the token through CREATE2, holds the supply, and pays it out as the ProjectFactory will.
///         Every leg must arrive whole and the supply must never change.
/// @dev The real floor (the protected custom-token test) additionally seeds a Uniswap v4 pool and
///      trades against it. A token with no transfer hooks or fees passes those flows by construction;
///      what is verified here is the arithmetic of the split and that nothing in the token depends
///      on who the caller is.
contract NukeTokenLaunchFlowTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_800;
    uint256 internal constant BPS = 10_000;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant POOL_MANAGER = address(0x900);
    address internal constant REMAINDER_TO = 0x6bF192eBEf135E0F645e99d59d9BF44E7711606c;
    address internal constant CLAIMANT = address(0xC1A1);

    FactoryProbe internal factory;
    NukeToken internal token;

    function setUp() public {
        factory = new FactoryProbe();
        token = NukeToken(factory.deploy(type(NukeToken).creationCode, bytes32(uint256(42))));
    }

    function test_create2DeploymentMintsToTheFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
    }

    function test_create2AddressIsPredictable() public view {
        bytes32 initHash = keccak256(type(NukeToken).creationCode);
        address predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(uint256(42)), initHash)))
            )
        );
        assertEq(address(token), predicted);
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // The creation code alone must deploy: nothing appended, nothing read from the chain.
        address at = factory.deploy(type(NukeToken).creationCode, bytes32(uint256(7)));
        assertEq(NukeToken(at).balanceOf(address(factory)), SUPPLY);
    }

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived short");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fullLaunchSplitIsExact() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        uint256 remainder = SUPPLY - swarm - pool;

        assertEq(swarm, 100_000_000 ether);
        assertEq(pool, 880_000_000 ether);
        assertEq(remainder, 20_000_000 ether);

        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertTrue(factory.move(token, POOL_MANAGER, pool));
        assertTrue(factory.move(token, REMAINDER_TO, remainder));

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    function test_poolManagerCanPayOutAndTakeInWhole() public {
        // A buyer receives exactly what the pool sends; a seller's tokens arrive at the pool whole.
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        factory.move(token, POOL_MANAGER, pool);

        address trader = makeAddr("trader");
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(trader, 1_000 ether));
        assertEq(token.balanceOf(trader), 1_000 ether, "a buy arrived short");

        // Sell path as the PoolManager settles it: trader approves, the pool pulls.
        vm.prank(trader);
        token.approve(POOL_MANAGER, 1_000 ether);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transferFrom(trader, POOL_MANAGER, 1_000 ether));
        assertEq(token.balanceOf(trader), 0, "a sell left something behind");
        assertEq(token.balanceOf(POOL_MANAGER), pool, "a sell arrived short");
    }

    function test_factoryCannotMintAfterLaunch() public {
        (bool ok,) = factory.call(address(token), abi.encodeWithSignature("mint(address,uint256)", address(factory), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryCannotMoveOrFreezeAHolder() public {
        address holder = makeAddr("holder");
        factory.move(token, holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);

        string[6] memory signatures = [
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "lock(address)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = factory.call(address(token), abi.encodeWithSignature(signatures[i], holder, true));
            assertFalse(ok, signatures[i]);
        }
        (bool pulled,) = factory.call(
            address(token), abi.encodeWithSelector(NukeToken.transferFrom.selector, holder, address(factory), 1)
        );
        assertFalse(pulled, "the factory moved a holder's balance without allowance");

        assertEq(token.balanceOf(holder), held);
        vm.prank(holder);
        assertTrue(token.transfer(CLAIMANT, held / 2));
        assertEq(token.balanceOf(CLAIMANT), held / 2);
    }
}

/// @dev Minimal stand-in for the ProjectFactory: deploys through CREATE2 and moves what it holds.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(NukeToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function call(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}
