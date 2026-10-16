// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RyfiniteToken} from "../src/RyfiniteToken.sol";

/// @dev Local deployment/transfer fixture, not a production factory or a pool implementation.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (RyfiniteToken) {
        return new RyfiniteToken{salt: salt}();
    }

    function send(RyfiniteToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "transfer failed");
    }
}

contract RejectingReceiverFixture {
    fallback() external {
        revert("ERC20 transfers must not call the receiver");
    }
}

/// forge-config: default.fuzz.runs = 1024
contract RyfiniteTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    RyfiniteToken internal token;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new RyfiniteToken();
    }

    function test_metadataAndInitialAllocation() public view {
        assertEq(token.name(), "Ryfinite Token");
        assertEq(token.symbol(), "RFN");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(deployer);
        RyfiniteToken fresh = new RyfiniteToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(deployer))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_factoryReceivesWholeSupplyAndLaunchTransfersAreExact() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        address distributor = makeAddr("distributor");
        address poolCustodian = makeAddr("pool custodian");
        address requester = makeAddr("requester");
        vm.prank(requester, requester);
        RyfiniteToken launched = factory.deploy(keccak256("RFN launch"));
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(requester), 0);
        assertEq(launched.balanceOf(address(this)), 0);

        factory.send(launched, distributor, SUPPLY / 10);
        factory.send(launched, poolCustodian, SUPPLY * 8 / 10);
        factory.send(launched, requester, SUPPLY / 10);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(poolCustodian), SUPPLY * 8 / 10);
        assertEq(launched.balanceOf(requester), SUPPLY / 10);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, SUPPLY / 10));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), SUPPLY / 10);

        // Exercise exact token movement both ways; this does not simulate Uniswap swaps.
        vm.prank(poolCustodian);
        assertTrue(launched.transfer(bob, 25 ether));
        assertEq(launched.balanceOf(bob), 25 ether);
        vm.prank(bob);
        assertTrue(launched.transfer(poolCustodian, 25 ether));
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(poolCustodian), SUPPLY * 8 / 10);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_transferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 123 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(deployer), SUPPLY - 123 ether);
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_entireSupplyCanBeTransferred() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_selfTransferPreservesBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToContractDoesNotInvokeCallback() public {
        RejectingReceiverFixture recipient = new RejectingReceiverFixture();
        vm.prank(deployer);
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferToZeroAlsoReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
    }

    function test_transferAboveBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(deployer);
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_selfTransferAboveBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
    }

    function test_approveEmitsEventAndDoesNotMoveFunds() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 100 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 100 ether));
        assertEq(token.allowance(deployer, spender), 100 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_approvalCanBeReplacedAndRevoked() public {
        vm.startPrank(deployer);
        assertTrue(token.approve(spender, 100 ether));
        assertTrue(token.approve(spender, 40 ether));
        assertEq(token.allowance(deployer, spender), 40 ether);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    function test_transferFromConsumesAllowanceAndEmitsTransfer() public {
        vm.prank(deployer);
        token.approve(spender, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, bob, 60 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));
        assertEq(token.balanceOf(deployer), SUPPLY - 60 ether);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.allowance(deployer, spender), 40 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 40 ether));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromInfiniteAllowanceDoesNotDecreaseIt() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, SUPPLY));
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_allowanceIsSpecificToSpender() public {
        vm.prank(deployer);
        token.approve(spender, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), 100 ether);
    }

    function test_transferFromAboveAllowanceReverts() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10, 11));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 11);
        assertEq(token.allowance(deployer, spender), 10);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromToZeroRollsBackAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 10);
        assertEq(token.allowance(deployer, spender), 10);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromZeroSenderRevertsEvenForZeroAmount() public {
        // Allowance validation rejects the zero owner before the transfer is reached.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
    }

    function test_selfTransferFromConsumesAllowanceButPreservesBalance() public {
        vm.prank(deployer);
        token.approve(spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 10));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_oneWeiCanBeTransferredAndReturnedThroughAllowance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        vm.prank(alice);
        assertTrue(token.approve(spender, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, deployer, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_largestFiniteAllowanceIsConsumed() public {
        uint256 approval = type(uint256).max - 1;
        vm.prank(deployer);
        assertTrue(token.approve(spender, approval));
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), approval - SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumTransferAmountRevertsDespiteInfiniteAllowance() public {
        uint256 amount = type(uint256).max;
        bytes memory error =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount);
        vm.expectRevert(error);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(deployer);
        assertTrue(token.approve(spender, amount));
        vm.expectRevert(error);
        vm.prank(spender);
        token.transferFrom(deployer, alice, amount);
        assertEq(token.allowance(deployer, spender), amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_revokingInfiniteAllowanceEmitsApprovalAndStopsSpending() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 0);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ownerTransferFromStillRequiresSelfApproval() public {
        vm.prank(deployer);
        token.transfer(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(alice);
        assertTrue(token.approve(alice, 1));
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_spendingAndRevocationDoNotAffectOtherOwnersOrSpenders() public {
        vm.startPrank(deployer);
        token.transfer(alice, 20);
        token.approve(spender, 9);
        token.approve(bob, 11);
        vm.stopPrank();
        vm.prank(alice);
        token.approve(spender, 13);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 3));
        assertEq(token.allowance(deployer, spender), 9);
        assertEq(token.allowance(deployer, bob), 11);
        assertEq(token.allowance(alice, spender), 10);
        vm.prank(deployer);
        token.approve(spender, 0);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.allowance(deployer, bob), 11);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(deployer), SUPPLY - 20);
        assertEq(token.balanceOf(alice), 17);
        assertEq(token.balanceOf(bob), 3);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_competingSpendersCannotSpendAnExhaustedBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(spender, 7);
        token.approve(bob, 7);
        vm.stopPrank();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, spender, 7));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 3, 7));
        vm.prank(bob);
        token.transferFrom(alice, bob, 7);
        assertEq(token.balanceOf(alice), 3);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 7);

        // A rejected spend must leave the approval usable when funds arrive later.
        vm.prank(deployer);
        token.transfer(alice, 4);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 7));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(spender), 7);
        assertEq(token.balanceOf(bob), 7);
        assertEq(token.balanceOf(deployer), SUPPLY - 14);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployerCannotSpendHolderFundsWithoutApproval() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
    }

    function test_noMintBurnOrAdministrativeEntryPoints() public {
        bytes[] memory calls = new bytes[](13);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("freeze(address)", alice);
        calls[8] = abi.encodeWithSignature("seize(address)", alice);
        calls[9] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[10] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[11] = abi.encodeWithSignature("initialize(address)", alice);
        calls[12] = abi.encodeWithSignature("setMinter(address)", alice);
        vm.prank(deployer);
        token.transfer(bob, 100 ether);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(deployer);
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(alice);
            (bool strangerSuccess,) = address(token).call(calls[i]);
            assertFalse(strangerSuccess);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY - 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100 ether);
        vm.prank(bob);
        assertTrue(token.transfer(alice, 100 ether));
    }

    function test_nativeEtherTransferReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 amount) public {
        recipient = address(uint160(bound(uint160(recipient), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(deployer), recipient == deployer ? SUPPLY : SUPPLY - amount);
        assertEq(token.balanceOf(recipient), recipient == deployer ? SUPPLY : amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transfersAboveBalanceRevert(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_approveOverwritesPreviousAllowance(uint256 previous, uint256 next) public {
        vm.startPrank(alice);
        assertTrue(token.approve(spender, previous));
        assertTrue(token.approve(spender, next));
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), next);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromSpendsOnlyApprovedAmount(uint256 approval, uint256 amount) public {
        approval = bound(approval, 0, SUPPLY);
        amount = bound(amount, 0, approval);
        vm.prank(deployer);
        token.approve(spender, approval);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(deployer, spender), approval - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientAllowanceDoesNotChangeState(uint256 approval, uint256 excess) public {
        approval = bound(approval, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - approval);
        uint256 amount = approval + excess;
        vm.prank(deployer);
        token.approve(spender, approval);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approval, amount)
        );
        vm.prank(spender);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, spender), approval);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_failedSpendCanBeRetriedAfterFunding(uint256 balance, uint256 shortfall) public {
        balance = bound(balance, 0, SUPPLY - 1);
        shortfall = bound(shortfall, 1, SUPPLY - balance);
        uint256 amount = balance + shortfall;
        vm.prank(deployer);
        token.transfer(alice, balance);
        vm.prank(alice);
        token.approve(spender, amount);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY - balance);

        vm.prank(deployer);
        token.transfer(alice, shortfall);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_zeroReceiverPreservesFiniteAllowanceForRetry(uint256 amount, uint256 approval) public {
        amount = bound(amount, 0, SUPPLY);
        approval = bound(approval, amount, type(uint256).max - 1);
        vm.prank(deployer);
        token.approve(spender, approval);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), amount);
        assertEq(token.allowance(deployer, spender), approval);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, spender), approval - amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_infiniteAllowanceSurvivesRepeatedRoundTrips(uint256 first, uint256 second) public {
        first = bound(first, 1, SUPPLY);
        second = bound(second, 1, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, first));
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(deployer), SUPPLY - first);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, first));

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, second));
        assertEq(token.balanceOf(bob), second);
        assertEq(token.balanceOf(deployer), SUPPLY - second);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        vm.prank(bob);
        assertTrue(token.transfer(deployer, second));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splittingTransfersMatchesOneTransfer(uint256 prefund, uint256 first, uint256 second) public {
        prefund = bound(prefund, 0, SUPPLY);
        first = bound(first, 0, SUPPLY - prefund);
        second = bound(second, 0, SUPPLY - prefund - first);
        vm.prank(deployer);
        RyfiniteToken singleTransfer = new RyfiniteToken();

        // Equivalent payment histories must have the same final state, including
        // when the recipient already holds tokens or the sender spends everything.
        vm.startPrank(deployer);
        assertTrue(token.transfer(alice, prefund));
        assertTrue(singleTransfer.transfer(alice, prefund));
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, second));
        assertTrue(singleTransfer.transfer(alice, first + second));
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), singleTransfer.balanceOf(deployer));
        assertEq(token.balanceOf(alice), singleTransfer.balanceOf(alice));
        assertEq(token.balanceOf(alice), prefund + first + second);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(singleTransfer.totalSupply(), SUPPLY);
    }

    function testFuzz_reducingAnAllowanceAfterSpendingRejectsTheOldLimit(
        uint256 approval,
        uint256 spent,
        uint256 replacement
    ) public {
        approval = bound(approval, 2, SUPPLY);
        spent = bound(spent, 1, approval - 1);
        replacement = bound(replacement, 0, approval - spent - 1);
        vm.prank(deployer);
        token.approve(spender, approval);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, spent));
        assertEq(token.allowance(deployer, spender), approval - spent);
        vm.prank(deployer);
        token.approve(spender, replacement);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, replacement, replacement + 1
            )
        );
        vm.prank(spender);
        token.transferFrom(deployer, bob, replacement + 1);
        assertEq(token.allowance(deployer, spender), replacement);
        assertEq(token.balanceOf(deployer), SUPPLY - spent);
        assertEq(token.balanceOf(bob), spent);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
