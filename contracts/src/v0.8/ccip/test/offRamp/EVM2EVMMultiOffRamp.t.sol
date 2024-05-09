// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Vm} from "forge-std/Vm.sol";

import {ICommitStore} from "../../interfaces/ICommitStore.sol";
import {IPool} from "../../interfaces/IPool.sol";

import {CallWithExactGas} from "../../../shared/call/CallWithExactGas.sol";

import {ARM} from "../../ARM.sol";
import {AggregateRateLimiter} from "../../AggregateRateLimiter.sol";
import {Router} from "../../Router.sol";
import {Client} from "../../libraries/Client.sol";
import {Internal} from "../../libraries/Internal.sol";
import {Pool} from "../../libraries/Pool.sol";
import {RateLimiter} from "../../libraries/RateLimiter.sol";
import {EVM2EVMMultiOffRamp} from "../../offRamp/EVM2EVMMultiOffRamp.sol";
import {LockReleaseTokenPool} from "../../pools/LockReleaseTokenPool.sol";
import {TokenPool} from "../../pools/TokenPool.sol";
import {EVM2EVMMultiOffRampHelper} from "../helpers/EVM2EVMMultiOffRampHelper.sol";
import {MaybeRevertingBurnMintTokenPool} from "../helpers/MaybeRevertingBurnMintTokenPool.sol";
import {ConformingReceiver} from "../helpers/receivers/ConformingReceiver.sol";
import {MaybeRevertMessageReceiver} from "../helpers/receivers/MaybeRevertMessageReceiver.sol";
import {MaybeRevertMessageReceiverNo165} from "../helpers/receivers/MaybeRevertMessageReceiverNo165.sol";
import {ReentrancyAbuser} from "../helpers/receivers/ReentrancyAbuser.sol";
import {MockCommitStore} from "../mocks/MockCommitStore.sol";
import {OCR2Base} from "../ocr/OCR2Base.t.sol";
import {OCR2BaseNoChecks} from "../ocr/OCR2BaseNoChecks.t.sol";
import {EVM2EVMMultiOffRampSetup} from "./EVM2EVMMultiOffRampSetup.t.sol";

import {IERC20} from "../../../vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

// TODO: re-use constants (SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1, etc.) in other tests

// TODO: re-add tests:
//       - execute_upgrade
//       - executeSingleMessage
//       - report
//       - manuallyExecute
//       - trialExecute
//       - getAllRateLimitTokens
//       - updateRateLimitTokens

contract EVM2EVMMultiOffRamp_constructor is EVM2EVMMultiOffRampSetup {
  event ConfigSet(EVM2EVMMultiOffRamp.StaticConfig staticConfig, EVM2EVMMultiOffRamp.DynamicConfig dynamicConfig);
  event SourceChainSelectorAdded(uint64 sourceChainSelector);
  event SourceChainConfigSet(uint64 indexed sourceChainSelector, EVM2EVMMultiOffRamp.SourceChainConfig sourceConfig);

  function test_Constructor_Success() public {
    EVM2EVMMultiOffRamp.StaticConfig memory staticConfig = EVM2EVMMultiOffRamp.StaticConfig({
      commitStore: address(s_mockCommitStore),
      chainSelector: DEST_CHAIN_SELECTOR,
      armProxy: address(s_mockARM)
    });
    EVM2EVMMultiOffRamp.DynamicConfig memory dynamicConfig =
      generateDynamicMultiOffRampConfig(address(s_destRouter), address(s_priceRegistry));

    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](2);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS
    });
    sourceChainConfigs[1] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR + 1,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: address(uint160(ON_RAMP_ADDRESS) + 1)
    });

    EVM2EVMMultiOffRamp.SourceChainConfig memory expectedSourceChainConfig1 = EVM2EVMMultiOffRamp.SourceChainConfig({
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: sourceChainConfigs[0].onRamp,
      metadataHash: s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR, sourceChainConfigs[0].onRamp)
    });

    EVM2EVMMultiOffRamp.SourceChainConfig memory expectedSourceChainConfig2 = EVM2EVMMultiOffRamp.SourceChainConfig({
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: sourceChainConfigs[1].onRamp,
      metadataHash: s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR + 1, sourceChainConfigs[1].onRamp)
    });

    vm.expectEmit();
    emit SourceChainSelectorAdded(SOURCE_CHAIN_SELECTOR);

    vm.expectEmit();
    emit SourceChainConfigSet(SOURCE_CHAIN_SELECTOR, expectedSourceChainConfig1);

    vm.expectEmit();
    emit SourceChainSelectorAdded(SOURCE_CHAIN_SELECTOR + 1);

    vm.expectEmit();
    emit SourceChainConfigSet(SOURCE_CHAIN_SELECTOR + 1, expectedSourceChainConfig2);

    s_offRamp = new EVM2EVMMultiOffRampHelper(staticConfig, sourceChainConfigs, getInboundRateLimiterConfig());

    s_offRamp.setOCR2Config(
      s_valid_signers, s_valid_transmitters, s_f, abi.encode(dynamicConfig), s_offchainConfigVersion, abi.encode("")
    );

    // Static config
    EVM2EVMMultiOffRamp.StaticConfig memory gotStaticConfig = s_offRamp.getStaticConfig();
    assertEq(staticConfig.commitStore, gotStaticConfig.commitStore);
    assertEq(staticConfig.chainSelector, gotStaticConfig.chainSelector);

    // Dynamic config
    EVM2EVMMultiOffRamp.DynamicConfig memory gotDynamicConfig = s_offRamp.getDynamicConfig();
    _assertSameConfig(dynamicConfig, gotDynamicConfig);

    (uint32 configCount, uint32 blockNumber,) = s_offRamp.latestConfigDetails();
    assertEq(1, configCount);
    assertEq(block.number, blockNumber);

    // Source config
    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    // uint64[] memory resultSourceChainSelectors = s_offRamp.getSourceChainSelectors();
    // assertEq(resultSourceChainSelectors.length, 2);
    // assertEq(resultSourceChainSelectors[0], SOURCE_CHAIN_SELECTOR);
    // assertEq(resultSourceChainSelectors[1], SOURCE_CHAIN_SELECTOR + 1);
    _assertSourceChainConfigEquality(s_offRamp.getSourceChainConfig(SOURCE_CHAIN_SELECTOR), expectedSourceChainConfig1);
    _assertSourceChainConfigEquality(
      s_offRamp.getSourceChainConfig(SOURCE_CHAIN_SELECTOR + 1), expectedSourceChainConfig2
    );

    // OffRamp initial values
    assertEq("EVM2EVMMultiOffRamp 1.6.0-dev", s_offRamp.typeAndVersion());
    assertEq(OWNER, s_offRamp.owner());
  }

  // Revert
  function test_ZeroOnRampAddress_Revert() public {
    uint64[] memory sourceChainSelectors = new uint64[](1);
    sourceChainSelectors[0] = SOURCE_CHAIN_SELECTOR;

    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](1);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: address(0)
    });

    vm.expectRevert(EVM2EVMMultiOffRamp.ZeroAddressNotAllowed.selector);

    s_offRamp = new EVM2EVMMultiOffRampHelper(
      EVM2EVMMultiOffRamp.StaticConfig({
        commitStore: address(s_mockCommitStore),
        chainSelector: DEST_CHAIN_SELECTOR,
        armProxy: address(s_mockARM)
      }),
      sourceChainConfigs,
      RateLimiter.Config({isEnabled: true, rate: 1e20, capacity: 1e20})
    );
  }

  // TODO: revisit in applySourceChainConfigUpdates after MultiCommitStore integration
  // function test_CommitStoreAlreadyInUse_Revert() public {
  //   s_mockCommitStore.setExpectedNextSequenceNumber(2);

  //   vm.expectRevert(EVM2EVMMultiOffRamp.CommitStoreAlreadyInUse.selector);

  //   s_offRamp = new EVM2EVMMultiOffRampHelper(
  //     EVM2EVMMultiOffRamp.StaticConfig({
  //       commitStore: address(s_mockCommitStore),
  //       chainSelector: DEST_CHAIN_SELECTOR,
  //       sourceChainSelector: SOURCE_CHAIN_SELECTOR,
  //       onRamp: ON_RAMP_ADDRESS,
  //       prevOffRamp: address(0),
  //       armProxy: address(s_mockARM)
  //     }),
  //     getInboundRateLimiterConfig()
  //   );
  // }
}

contract EVM2EVMMultiOffRamp_setDynamicConfig is EVM2EVMMultiOffRampSetup {
  // OffRamp event
  event ConfigSet(EVM2EVMMultiOffRamp.StaticConfig staticConfig, EVM2EVMMultiOffRamp.DynamicConfig dynamicConfig);

  function test_SetDynamicConfig_Success() public {
    EVM2EVMMultiOffRamp.StaticConfig memory staticConfig = s_offRamp.getStaticConfig();
    EVM2EVMMultiOffRamp.DynamicConfig memory dynamicConfig =
      generateDynamicMultiOffRampConfig(USER_3, address(s_priceRegistry));
    bytes memory onchainConfig = abi.encode(dynamicConfig);

    vm.expectEmit();
    emit ConfigSet(staticConfig, dynamicConfig);

    vm.expectEmit();
    uint32 configCount = 1;
    emit ConfigSet(
      uint32(block.number),
      getBasicConfigDigest(address(s_offRamp), s_f, configCount, onchainConfig),
      configCount + 1,
      s_valid_signers,
      s_valid_transmitters,
      s_f,
      onchainConfig,
      s_offchainConfigVersion,
      abi.encode("")
    );

    s_offRamp.setOCR2Config(
      s_valid_signers, s_valid_transmitters, s_f, onchainConfig, s_offchainConfigVersion, abi.encode("")
    );

    EVM2EVMMultiOffRamp.DynamicConfig memory newConfig = s_offRamp.getDynamicConfig();
    _assertSameConfig(dynamicConfig, newConfig);
  }

  function test_NonOwner_Revert() public {
    vm.startPrank(STRANGER);
    EVM2EVMMultiOffRamp.DynamicConfig memory dynamicConfig =
      generateDynamicMultiOffRampConfig(USER_3, address(s_priceRegistry));

    vm.expectRevert("Only callable by owner");

    s_offRamp.setOCR2Config(
      s_valid_signers, s_valid_transmitters, s_f, abi.encode(dynamicConfig), s_offchainConfigVersion, abi.encode("")
    );
  }

  function test_RouterZeroAddress_Revert() public {
    EVM2EVMMultiOffRamp.DynamicConfig memory dynamicConfig =
      generateDynamicMultiOffRampConfig(ZERO_ADDRESS, ZERO_ADDRESS);

    vm.expectRevert(EVM2EVMMultiOffRamp.ZeroAddressNotAllowed.selector);

    s_offRamp.setOCR2Config(
      s_valid_signers, s_valid_transmitters, s_f, abi.encode(dynamicConfig), s_offchainConfigVersion, abi.encode("")
    );
  }
}

contract EVM2EVMMultiOffRamp_metadataHash is EVM2EVMMultiOffRampSetup {
  function test_MetadataHash_Success() public view {
    bytes32 h = s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR, ON_RAMP_ADDRESS);
    assertEq(
      h,
      keccak256(
        abi.encode(Internal.EVM_2_EVM_MESSAGE_HASH, SOURCE_CHAIN_SELECTOR, DEST_CHAIN_SELECTOR, ON_RAMP_ADDRESS)
      )
    );
  }

  function test_MetadataHashChangesOnSourceChain_Success() public view {
    bytes32 h = s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR + 1, ON_RAMP_ADDRESS);
    assertEq(
      h,
      keccak256(
        abi.encode(Internal.EVM_2_EVM_MESSAGE_HASH, SOURCE_CHAIN_SELECTOR + 1, DEST_CHAIN_SELECTOR, ON_RAMP_ADDRESS)
      )
    );
    assertTrue(h != s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR, ON_RAMP_ADDRESS));
  }

  function test_MetadataHashChangesOnOnRampAddress_Success() public view {
    address mockOnRampAddress = address(uint160(ON_RAMP_ADDRESS) + 1);
    bytes32 h = s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR, mockOnRampAddress);
    assertEq(
      h,
      keccak256(
        abi.encode(Internal.EVM_2_EVM_MESSAGE_HASH, SOURCE_CHAIN_SELECTOR, DEST_CHAIN_SELECTOR, mockOnRampAddress)
      )
    );
    assertTrue(h != s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR, ON_RAMP_ADDRESS));
  }

  // NOTE: to get a reliable result, set fuzz runs to at least 1mil
  /// forge-config: default.fuzz.runs = 32
  /// forge-config: ccip.fuzz.runs = 10000
  function test_fuzz__MetadataHash_NoCollisions(
    uint64 destChainSelector,
    uint64 sourceChainSelector1,
    uint64 sourceChainSelector2,
    address onRamp1,
    address onRamp2
  ) public {
    // Edge case: metadata hash should be the same when values match
    if (sourceChainSelector1 == sourceChainSelector2 && onRamp1 == onRamp2) {
      return;
    }

    EVM2EVMMultiOffRamp.StaticConfig memory staticConfig = s_offRamp.getStaticConfig();
    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](0);

    staticConfig.chainSelector = destChainSelector;
    s_offRamp = new EVM2EVMMultiOffRampHelper(staticConfig, sourceChainConfigs, getInboundRateLimiterConfig());

    bytes32 h1 = s_offRamp.metadataHash(sourceChainSelector1, onRamp1);
    bytes32 h2 = s_offRamp.metadataHash(sourceChainSelector2, onRamp2);

    assertTrue(h1 != h2);
  }
}

contract EVM2EVMMultiOffRamp_ccipReceive is EVM2EVMMultiOffRampSetup {
  // Reverts

  function test_Reverts() public {
    Client.Any2EVMMessage memory message =
      _convertToGeneralMessage(_generateAny2EVMMessageNoTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1, 1));
    vm.expectRevert();
    s_offRamp.ccipReceive(message);
  }
}

contract EVM2EVMMultiOffRamp_execute is EVM2EVMMultiOffRampSetup {
  error PausedError();

  function setUp() public virtual override {
    super.setUp();

    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](3);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS_1
    });
    sourceChainConfigs[1] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_2,
      isEnabled: false,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS_2
    });
    sourceChainConfigs[2] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_3,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS_3
    });

    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    Router.OnRamp[] memory onRampUpdates = new Router.OnRamp[](3);
    Router.OffRamp[] memory offRampUpdates = new Router.OffRamp[](6);

    for (uint256 i = 0; i < sourceChainConfigs.length; ++i) {
      uint64 sourceChainSelector = sourceChainConfigs[i].sourceChainSelector;

      onRampUpdates[i] = Router.OnRamp({destChainSelector: DEST_CHAIN_SELECTOR, onRamp: sourceChainConfigs[i].onRamp});

      offRampUpdates[2 * i] = Router.OffRamp({sourceChainSelector: sourceChainSelector, offRamp: address(s_offRamp)});
      offRampUpdates[2 * i + 1] =
        Router.OffRamp({sourceChainSelector: sourceChainSelector, offRamp: address(sourceChainConfigs[i].prevOffRamp)});
    }

    s_destRouter.applyRampUpdates(onRampUpdates, new Router.OffRamp[](0), offRampUpdates);
  }

  function test_SingleMessageNoTokens_Success() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    vm.expectEmit();
    emit ExecutionStateChanged(
      messages[0].sourceChainSelector,
      messages[0].sequenceNumber,
      messages[0].messageId,
      Internal.MessageExecutionState.SUCCESS,
      ""
    );

    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));

    messages[0].nonce++;
    messages[0].sequenceNumber++;
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

    vm.expectEmit();
    emit ExecutionStateChanged(
      messages[0].sourceChainSelector,
      messages[0].sequenceNumber,
      messages[0].messageId,
      Internal.MessageExecutionState.SUCCESS,
      ""
    );

    uint64 nonceBefore = s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, messages[0].sender);
    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
    assertGt(s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, messages[0].sender), nonceBefore);
  }

  function test_SingleMessageNoTokensOtherChain_Success() public {
    Internal.EVM2EVMMessage[] memory messagesChain1 = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    s_offRamp.execute(_generateReportFromMessages(messagesChain1), new uint256[](0));

    uint64 nonceChain1 = s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, messagesChain1[0].sender);
    assertGt(nonceChain1, 0);

    Internal.EVM2EVMMessage[] memory messagesChain2 = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_3, ON_RAMP_ADDRESS_3);
    assertEq(s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_3, messagesChain2[0].sender), 0);

    s_offRamp.execute(_generateReportFromMessages(messagesChain2), new uint256[](0));
    assertGt(s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_3, messagesChain2[0].sender), 0);

    // Other chain's nonce is unaffected
    assertEq(s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, messagesChain1[0].sender), nonceChain1);
  }

  function test_ReceiverError_Success() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);

    bytes memory realError1 = new bytes(2);
    realError1[0] = 0xbe;
    realError1[1] = 0xef;
    s_reverting_receiver.setErr(realError1);

    messages[0].receiver = address(s_reverting_receiver);
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

    vm.expectEmit();
    emit ExecutionStateChanged(
      messages[0].sourceChainSelector,
      messages[0].sequenceNumber,
      messages[0].messageId,
      Internal.MessageExecutionState.FAILURE,
      abi.encodeWithSelector(
        EVM2EVMMultiOffRamp.ReceiverError.selector,
        abi.encodeWithSelector(MaybeRevertMessageReceiver.CustomError.selector, realError1)
      )
    );
    // Nonce should increment on non-strict
    assertEq(uint64(0), s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, address(OWNER)));
    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
    assertEq(uint64(1), s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, address(OWNER)));
  }

  function test_SkippedIncorrectNonce_Success() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);

    messages[0].nonce++;
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

    vm.expectEmit();
    emit SkippedIncorrectNonce(messages[0].sourceChainSelector, messages[0].nonce, messages[0].sender);

    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
  }

  // TODO: re-do test after pulling in pool interface changes
  // function test_SkippedIncorrectNonceStillExecutes_Success() public {
  //   Internal.EVM2EVMMessage[] memory messages = _generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);

  //   messages[1].nonce++;
  //   messages[1].messageId = Internal._hash(messages[1], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

  //   vm.expectEmit();
  //   emit ExecutionStateChanged(
  //     messages[0].sequenceNumber, messages[0].messageId, Internal.MessageExecutionState.SUCCESS, ""
  //   );

  //   vm.expectEmit();
  //   emit SkippedIncorrectNonce(messages[1].nonce, messages[1].sender);

  //   s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
  // }

  // Send a message to a contract that does not implement the CCIPReceiver interface
  // This should execute successfully.
  function test_SingleMessageToNonCCIPReceiver_Success() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    MaybeRevertMessageReceiverNo165 newReceiver = new MaybeRevertMessageReceiverNo165(true);
    messages[0].receiver = address(newReceiver);
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

    vm.expectEmit();
    emit ExecutionStateChanged(
      messages[0].sourceChainSelector,
      messages[0].sequenceNumber,
      messages[0].messageId,
      Internal.MessageExecutionState.SUCCESS,
      ""
    );

    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
  }

  function test_SingleMessagesNoTokensSuccess_gas() public {
    vm.pauseGasMetering();
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);

    vm.expectEmit();
    emit ExecutionStateChanged(
      messages[0].sourceChainSelector,
      messages[0].sequenceNumber,
      messages[0].messageId,
      Internal.MessageExecutionState.SUCCESS,
      ""
    );

    Internal.ExecutionReport memory report = _generateReportFromMessages(messages);

    vm.resumeGasMetering();
    s_offRamp.execute(report, new uint256[](0));
  }

  // TODO: re-do test after pulling in pool interface changes
  // function test_TwoMessagesWithTokensSuccess_gas() public {
  //   vm.pauseGasMetering();
  //   Internal.EVM2EVMMessage[] memory messages = _generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
  //   // Set message 1 to use another receiver to simulate more fair gas costs
  //   messages[1].receiver = address(s_secondary_receiver);
  //   messages[1].messageId = Internal._hash(messages[1], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

  //   vm.expectEmit();
  //   emit ExecutionStateChanged(
  //     messages[0].sequenceNumber, messages[0].messageId, Internal.MessageExecutionState.SUCCESS, ""
  //   );

  //   vm.expectEmit();
  //   emit ExecutionStateChanged(
  //     messages[1].sequenceNumber, messages[1].messageId, Internal.MessageExecutionState.SUCCESS, ""
  //   );

  //   Internal.ExecutionReport memory report = _generateReportFromMessages(messages);

  //   vm.resumeGasMetering();
  //   s_offRamp.execute(report, new uint256[](0));
  // }

  // TODO: re-do test after pulling in pool interface changes
  // function test_TwoMessagesWithTokensAndGE_Success() public {
  //   Internal.EVM2EVMMessage[] memory messages = _generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
  //   // Set message 1 to use another receiver to simulate more fair gas costs
  //   messages[1].receiver = address(s_secondary_receiver);
  //   messages[1].messageId = Internal._hash(messages[1], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

  //   vm.expectEmit();
  //   emit ExecutionStateChanged(
  //     messages[0].sequenceNumber, messages[0].messageId, Internal.MessageExecutionState.SUCCESS, ""
  //   );

  //   vm.expectEmit();
  //   emit ExecutionStateChanged(
  //     messages[1].sequenceNumber, messages[1].messageId, Internal.MessageExecutionState.SUCCESS, ""
  //   );

  //   assertEq(uint64(0), s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, OWNER));
  //   s_offRamp.execute(_generateReportFromMessages(messages), _getGasLimitsFromMessages(messages));
  //   assertEq(uint64(2), s_offRamp.getSenderNonce(SOURCE_CHAIN_SELECTOR_1, OWNER));
  // }

  // TODO: re-do test after pulling in pool interface changes
  // function test_InvalidSourcePoolAddress_Success() public {
  //   address fakePoolAddress = address(0x0000000000333333);

  //   Internal.EVM2EVMMessage[] memory messages = _generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
  //   messages[0].sourceTokenData[0] = abi.encode(
  //     IPool.SourceTokenData({
  //       sourcePoolAddress: abi.encode(fakePoolAddress),
  //       destPoolAddress: abi.encode(s_destPoolBySourceToken[messages[0].tokenAmounts[0].token]),
  //       extraData: ""
  //     })
  //   );

  //   messages[0].messageId = Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));
  //   messages[1].messageId = Internal._hash(messages[1], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

  //   vm.expectEmit();
  //   emit ExecutionStateChanged(
  //     messages[0].sequenceNumber,
  //     messages[0].messageId,
  //     Internal.MessageExecutionState.FAILURE,
  //     abi.encodeWithSelector(
  //       EVM2EVMMultiOffRamp.TokenHandlingError.selector,
  //       abi.encodeWithSelector(TokenPool.InvalidSourcePoolAddress.selector, abi.encode(fakePoolAddress))
  //     )
  //   );

  //   s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
  // }

  // Reverts

  function test_InvalidMessageId_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    messages[0].nonce++;
    // MessageID no longer matches hash.
    Internal.ExecutionReport memory executionReport = _generateReportFromMessages(messages);
    vm.expectRevert(EVM2EVMMultiOffRamp.InvalidMessageId.selector);
    s_offRamp.execute(executionReport, new uint256[](0));
  }

  function test_MismatchingSourceChainSelector_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    messages[0].sourceChainSelector = SOURCE_CHAIN_SELECTOR_3;
    // MessageID no longer matches hash.
    Internal.ExecutionReport memory executionReport = _generateReportFromMessages(messages);
    vm.expectRevert(EVM2EVMMultiOffRamp.InvalidMessageId.selector);
    s_offRamp.execute(executionReport, new uint256[](0));
  }

  function test_MismatchingOnRampAddress_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_3));
    // MessageID no longer matches hash.
    Internal.ExecutionReport memory executionReport = _generateReportFromMessages(messages);
    vm.expectRevert(EVM2EVMMultiOffRamp.InvalidMessageId.selector);
    s_offRamp.execute(executionReport, new uint256[](0));
  }

  function test_Paused_Revert() public {
    s_mockCommitStore.pause();
    vm.expectRevert(PausedError.selector);
    s_offRamp.execute(
      _generateReportFromMessages(_generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1)),
      new uint256[](0)
    );
  }

  function test_Unhealthy_Revert() public {
    s_mockARM.voteToCurse(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    vm.expectRevert(EVM2EVMMultiOffRamp.BadARMSignal.selector);
    s_offRamp.execute(
      _generateReportFromMessages(_generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1)),
      new uint256[](0)
    );
    // Uncurse should succeed
    ARM.UnvoteToCurseRecord[] memory records = new ARM.UnvoteToCurseRecord[](1);
    records[0] = ARM.UnvoteToCurseRecord({curseVoteAddr: OWNER, cursesHash: bytes32(uint256(0)), forceUnvote: true});
    s_mockARM.ownerUnvoteToCurse(records);
    s_offRamp.execute(
      _generateReportFromMessages(_generateMessagesWithTokens(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1)),
      new uint256[](0)
    );
  }

  function test_UnexpectedTokenData_Revert() public {
    Internal.ExecutionReport memory report =
      _generateReportFromMessages(_generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));
    report.offchainTokenData = new bytes[][](report.messages.length + 1);

    vm.expectRevert(EVM2EVMMultiOffRamp.UnexpectedTokenData.selector);

    s_offRamp.execute(report, new uint256[](0));
  }

  function test_EmptyReport_Revert() public {
    vm.expectRevert(EVM2EVMMultiOffRamp.EmptyReport.selector);
    s_offRamp.execute(
      Internal.ExecutionReport({
        proofs: new bytes32[](0),
        proofFlagBits: 0,
        messages: new Internal.EVM2EVMMessage[](0),
        offchainTokenData: new bytes[][](0)
      }),
      new uint256[](0)
    );
  }

  function test_RootNotCommitted_Revert() public {
    vm.mockCall(address(s_mockCommitStore), abi.encodeWithSelector(ICommitStore.verify.selector), abi.encode(0));
    vm.expectRevert(EVM2EVMMultiOffRamp.RootNotCommitted.selector);

    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    s_offRamp.execute(_generateReportFromMessages(messages), _getGasLimitsFromMessages(messages));
    vm.clearMockedCalls();
  }

  function test_ManualExecutionNotYetEnabled_Revert() public {
    vm.mockCall(
      address(s_mockCommitStore), abi.encodeWithSelector(ICommitStore.verify.selector), abi.encode(BLOCK_TIME)
    );
    vm.expectRevert(EVM2EVMMultiOffRamp.ManualExecutionNotYetEnabled.selector);

    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    s_offRamp.execute(_generateReportFromMessages(messages), _getGasLimitsFromMessages(messages));
    vm.clearMockedCalls();
  }

  function test_AlreadyExecuted_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    Internal.ExecutionReport memory executionReport = _generateReportFromMessages(messages);
    s_offRamp.execute(executionReport, new uint256[](0));
    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.AlreadyExecuted.selector, messages[0].sequenceNumber));
    s_offRamp.execute(executionReport, new uint256[](0));
  }

  function test_NonExistingSourceChain_Revert() public {
    uint64 newSourceChainSelector = SOURCE_CHAIN_SELECTOR_1 + 1;
    address newOnRamp = address(uint160(ON_RAMP_ADDRESS_1) + 1);

    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(newSourceChainSelector, newOnRamp);

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.SourceChainNotEnabled.selector, newSourceChainSelector));
    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
  }

  function test_DisabledSourceChain_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_2, ON_RAMP_ADDRESS_2);

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.SourceChainNotEnabled.selector, SOURCE_CHAIN_SELECTOR_2));
    s_offRamp.execute(_generateReportFromMessages(messages), new uint256[](0));
  }

  function test_UnsupportedNumberOfTokens_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    Client.EVMTokenAmount[] memory newTokens = new Client.EVMTokenAmount[](MAX_TOKENS_LENGTH + 1);
    messages[0].tokenAmounts = newTokens;
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));
    Internal.ExecutionReport memory report = _generateReportFromMessages(messages);

    vm.expectRevert(
      abi.encodeWithSelector(EVM2EVMMultiOffRamp.UnsupportedNumberOfTokens.selector, messages[0].sequenceNumber)
    );
    s_offRamp.execute(report, new uint256[](0));
  }

  function test_TokenDataMismatch_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    Internal.ExecutionReport memory report = _generateReportFromMessages(messages);

    report.offchainTokenData[0] = new bytes[](messages[0].tokenAmounts.length + 1);

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.TokenDataMismatch.selector, messages[0].sequenceNumber));
    s_offRamp.execute(report, new uint256[](0));
  }

  function test_MessageTooLarge_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);
    messages[0].data = new bytes(MAX_DATA_SIZE + 1);
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

    Internal.ExecutionReport memory executionReport = _generateReportFromMessages(messages);
    vm.expectRevert(
      abi.encodeWithSelector(EVM2EVMMultiOffRamp.MessageTooLarge.selector, MAX_DATA_SIZE, messages[0].data.length)
    );
    s_offRamp.execute(executionReport, new uint256[](0));
  }

  function test_RouterYULCall_Revert() public {
    Internal.EVM2EVMMessage[] memory messages = _generateBasicMessages(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1);

    // gas limit too high, Router's external call should revert
    messages[0].gasLimit = 1e36;
    messages[0].receiver = address(new ConformingReceiver(address(s_destRouter), s_destFeeToken));
    messages[0].messageId =
      Internal._hash(messages[0], s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS_1));

    Internal.ExecutionReport memory executionReport = _generateReportFromMessages(messages);

    vm.expectRevert(
      abi.encodeWithSelector(
        EVM2EVMMultiOffRamp.ExecutionError.selector,
        abi.encodeWithSelector(CallWithExactGas.NotEnoughGasForCall.selector)
      )
    );
    s_offRamp.execute(executionReport, new uint256[](0));
  }
}

contract EVM2EVMMultiOffRamp_getExecutionState is EVM2EVMMultiOffRampSetup {
  mapping(uint64 sourceChainSelector => mapping(uint64 seqNum => Internal.MessageExecutionState state)) internal
    s_differentialExecutionState;

  /// forge-config: default.fuzz.runs = 32
  /// forge-config: ccip.fuzz.runs = 32
  function test_Fuzz_Differential_Success(
    uint64 sourceChainSelector,
    uint16[500] memory seqNums,
    uint8[500] memory values
  ) public {
    for (uint256 i = 0; i < seqNums.length; ++i) {
      // Only use the first three slots. This makes sure existing slots get overwritten
      // as the tests uses 500 sequence numbers.
      uint16 seqNum = seqNums[i] % 386;
      Internal.MessageExecutionState state = Internal.MessageExecutionState(values[i] % 4);
      s_differentialExecutionState[sourceChainSelector][seqNum] = state;
      s_offRamp.setExecutionStateHelper(sourceChainSelector, seqNum, state);
      assertEq(uint256(state), uint256(s_offRamp.getExecutionState(sourceChainSelector, seqNum)));
    }

    for (uint256 i = 0; i < seqNums.length; ++i) {
      uint16 seqNum = seqNums[i] % 386;
      Internal.MessageExecutionState expectedState = s_differentialExecutionState[sourceChainSelector][seqNum];
      assertEq(uint256(expectedState), uint256(s_offRamp.getExecutionState(sourceChainSelector, seqNum)));
    }
  }

  function test_GetExecutionState_Success() public {
    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 0, Internal.MessageExecutionState.FAILURE);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3);

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 1, Internal.MessageExecutionState.FAILURE);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (3 << 2));

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 1, Internal.MessageExecutionState.IN_PROGRESS);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 2));

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 2, Internal.MessageExecutionState.FAILURE);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 2) + (3 << 4));

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 127, Internal.MessageExecutionState.IN_PROGRESS);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 2) + (3 << 4) + (1 << 254));

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 128, Internal.MessageExecutionState.SUCCESS);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 2) + (3 << 4) + (1 << 254));
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 1), 2);

    assertEq(
      uint256(Internal.MessageExecutionState.FAILURE), uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 0))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.IN_PROGRESS),
      uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 1))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.FAILURE), uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 2))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.IN_PROGRESS),
      uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 127))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.SUCCESS), uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 128))
    );
  }

  function test_GetDifferentChainExecutionState_Success() public {
    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 0, Internal.MessageExecutionState.FAILURE);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR + 1, 0), 0);

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 127, Internal.MessageExecutionState.IN_PROGRESS);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 254));
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR + 1, 0), 0);

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, 128, Internal.MessageExecutionState.SUCCESS);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 254));
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 1), 2);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR + 1, 0), 0);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR + 1, 1), 0);

    s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR + 1, 127, Internal.MessageExecutionState.FAILURE);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 0), 3 + (1 << 254));
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, 1), 2);
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR + 1, 0), (3 << 254));
    assertEq(s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR + 1, 1), 0);

    assertEq(
      uint256(Internal.MessageExecutionState.FAILURE), uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 0))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.IN_PROGRESS),
      uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 127))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.SUCCESS), uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, 128))
    );

    assertEq(
      uint256(Internal.MessageExecutionState.UNTOUCHED),
      uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR + 1, 0))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.FAILURE),
      uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR + 1, 127))
    );
    assertEq(
      uint256(Internal.MessageExecutionState.UNTOUCHED),
      uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR + 1, 128))
    );
  }

  function test_FillExecutionState_Success() public {
    for (uint64 i = 0; i < 384; ++i) {
      s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, i, Internal.MessageExecutionState.FAILURE);
    }

    for (uint64 i = 0; i < 384; ++i) {
      assertEq(
        uint256(Internal.MessageExecutionState.FAILURE), uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, i))
      );
    }

    for (uint64 i = 0; i < 3; ++i) {
      assertEq(type(uint256).max, s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, i));
    }

    for (uint64 i = 0; i < 384; ++i) {
      s_offRamp.setExecutionStateHelper(SOURCE_CHAIN_SELECTOR, i, Internal.MessageExecutionState.IN_PROGRESS);
    }

    for (uint64 i = 0; i < 384; ++i) {
      assertEq(
        uint256(Internal.MessageExecutionState.IN_PROGRESS),
        uint256(s_offRamp.getExecutionState(SOURCE_CHAIN_SELECTOR, i))
      );
    }

    for (uint64 i = 0; i < 3; ++i) {
      // 0x555... == 0b101010101010.....
      assertEq(
        0x5555555555555555555555555555555555555555555555555555555555555555,
        s_offRamp.getExecutionStateBitMap(SOURCE_CHAIN_SELECTOR, i)
      );
    }
  }
}

contract EVM2EVMMultiOffRamp__releaseOrMintTokens is EVM2EVMMultiOffRampSetup {
  EVM2EVMMultiOffRamp.Any2EVMMessageRoute internal MESSAGE_ROUTE;

  function setUp() public virtual override {
    super.setUp();
    MESSAGE_ROUTE = EVM2EVMMultiOffRamp.Any2EVMMessageRoute({
      sender: abi.encode(OWNER),
      sourceChainSelector: SOURCE_CHAIN_SELECTOR,
      receiver: OWNER
    });

    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](1);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS
    });

    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    Router.OnRamp[] memory onRampUpdates = new Router.OnRamp[](0);
    Router.OffRamp[] memory offRampUpdates = new Router.OffRamp[](2);

    offRampUpdates[0] = Router.OffRamp({sourceChainSelector: SOURCE_CHAIN_SELECTOR, offRamp: address(s_offRamp)});
    offRampUpdates[1] = Router.OffRamp({sourceChainSelector: SOURCE_CHAIN_SELECTOR, offRamp: address(0)});

    s_destRouter.applyRampUpdates(onRampUpdates, new Router.OffRamp[](0), offRampUpdates);
  }

  function test_releaseOrMintTokens_Success() public {
    Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();
    IERC20 dstToken1 = IERC20(s_destFeeToken);
    uint256 startingBalance = dstToken1.balanceOf(OWNER);
    uint256 amount1 = 100;
    srcTokenAmounts[0].amount = amount1;

    bytes[] memory offchainTokenData = new bytes[](srcTokenAmounts.length);
    offchainTokenData[0] = abi.encode(0x12345678);

    bytes[] memory encodedSourceTokenData = _getDefaultSourceTokenData(srcTokenAmounts);
    Internal.SourceTokenData memory sourceTokenData = abi.decode(encodedSourceTokenData[0], (Internal.SourceTokenData));

    vm.expectCall(
      s_destPoolBySourceToken[srcTokenAmounts[0].token],
      abi.encodeWithSelector(
        LockReleaseTokenPool.releaseOrMint.selector,
        Pool.ReleaseOrMintInV1({
          originalSender: MESSAGE_ROUTE.sender,
          receiver: MESSAGE_ROUTE.receiver,
          amount: srcTokenAmounts[0].amount,
          remoteChainSelector: MESSAGE_ROUTE.sourceChainSelector,
          sourcePoolAddress: sourceTokenData.sourcePoolAddress,
          sourcePoolData: sourceTokenData.extraData,
          offchainTokenData: offchainTokenData[0]
        })
      )
    );

    s_offRamp.releaseOrMintTokens(srcTokenAmounts, MESSAGE_ROUTE, encodedSourceTokenData, offchainTokenData);

    assertEq(startingBalance + amount1, dstToken1.balanceOf(OWNER));
  }

  function test_releaseOrMintTokens_destDenominatedDecimals_Success() public {
    Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();
    address destToken = s_destFeeToken;
    uint256 amount = 100;
    uint256 destinationDenominationMultiplier = 1000;
    srcTokenAmounts[0].amount = amount;

    bytes[] memory offchainTokenData = new bytes[](srcTokenAmounts.length);
    bytes[] memory encodedSourceTokenData = _getDefaultSourceTokenData(srcTokenAmounts);
    Internal.SourceTokenData memory sourceTokenData = abi.decode(encodedSourceTokenData[0], (Internal.SourceTokenData));

    vm.mockCall(
      s_destPoolBySourceToken[srcTokenAmounts[0].token],
      abi.encodeWithSelector(
        LockReleaseTokenPool.releaseOrMint.selector,
        Pool.ReleaseOrMintInV1({
          originalSender: MESSAGE_ROUTE.sender,
          receiver: MESSAGE_ROUTE.receiver,
          amount: amount,
          remoteChainSelector: MESSAGE_ROUTE.sourceChainSelector,
          sourcePoolAddress: sourceTokenData.sourcePoolAddress,
          sourcePoolData: sourceTokenData.extraData,
          offchainTokenData: offchainTokenData[0]
        })
      ),
      abi.encode(destToken, amount * destinationDenominationMultiplier)
    );

    Client.EVMTokenAmount[] memory destTokenAmounts =
      s_offRamp.releaseOrMintTokens(srcTokenAmounts, MESSAGE_ROUTE, encodedSourceTokenData, offchainTokenData);

    assertEq(destTokenAmounts[0].amount, amount * destinationDenominationMultiplier);
    assertEq(destTokenAmounts[0].token, destToken);
  }

  // TODO: re-add after ARL changes
  // function test_OverValueWithARLOff_Success() public {
  //   // Set a high price to trip the ARL
  //   uint224 tokenPrice = 3 ** 128;
  //   Internal.PriceUpdates memory priceUpdates = getSingleTokenPriceUpdateStruct(s_destFeeToken, tokenPrice);
  //   s_priceRegistry.updatePrices(priceUpdates);

  //   Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();
  //   uint256 amount1 = 100;
  //   srcTokenAmounts[0].amount = amount1;

  //   bytes memory originalSender = abi.encode(OWNER);

  //   bytes[] memory offchainTokenData = new bytes[](srcTokenAmounts.length);
  //   offchainTokenData[0] = abi.encode(0x12345678);

  //   bytes[] memory sourceTokenData = _getDefaultSourceTokenData(srcTokenAmounts);

  //   vm.expectRevert(
  //     abi.encodeWithSelector(
  //       RateLimiter.AggregateValueMaxCapacityExceeded.selector,
  //       getInboundRateLimiterConfig().capacity,
  //       (amount1 * tokenPrice) / 1e18
  //     )
  //   );

  //   // // Expect to fail from ARL
  //   s_offRamp.releaseOrMintTokens(srcTokenAmounts, originalSender, OWNER, sourceTokenData, offchainTokenData);

  //   // Configure ARL off for token
  //   EVM2EVMMultiOffRamp.RateLimitToken[] memory removes = new EVM2EVMMultiOffRamp.RateLimitToken[](1);
  //   removes[0] = EVM2EVMMultiOffRamp.RateLimitToken({sourceToken: s_sourceFeeToken, destToken: s_destFeeToken});
  //   s_offRamp.updateRateLimitTokens(removes, new EVM2EVMMultiOffRamp.RateLimitToken[](0));

  //   // Expect the call now succeeds
  //   s_offRamp.releaseOrMintTokens(srcTokenAmounts, originalSender, OWNER, sourceTokenData, offchainTokenData);
  // }

  // Revert

  function test_TokenHandlingError_Reverts() public {
    Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();

    bytes memory unknownError = bytes("unknown error");
    s_maybeRevertingPool.setShouldRevert(unknownError);

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.TokenHandlingError.selector, unknownError));

    s_offRamp.releaseOrMintTokens(
      srcTokenAmounts, MESSAGE_ROUTE, _getDefaultSourceTokenData(srcTokenAmounts), new bytes[](srcTokenAmounts.length)
    );
  }

  function test_releaseOrMintTokens_InvalidDataLengthReturnData_Revert() public {
    uint256 amount = 100;
    Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();
    srcTokenAmounts[0].amount = amount;

    bytes[] memory offchainTokenData = new bytes[](srcTokenAmounts.length);
    bytes[] memory encodedSourceTokenData = _getDefaultSourceTokenData(srcTokenAmounts);
    Internal.SourceTokenData memory sourceTokenData = abi.decode(encodedSourceTokenData[0], (Internal.SourceTokenData));

    vm.mockCall(
      s_destPoolBySourceToken[srcTokenAmounts[0].token],
      abi.encodeWithSelector(
        LockReleaseTokenPool.releaseOrMint.selector,
        Pool.ReleaseOrMintInV1({
          originalSender: MESSAGE_ROUTE.sender,
          receiver: MESSAGE_ROUTE.receiver,
          amount: amount,
          remoteChainSelector: MESSAGE_ROUTE.sourceChainSelector,
          sourcePoolAddress: sourceTokenData.sourcePoolAddress,
          sourcePoolData: sourceTokenData.extraData,
          offchainTokenData: offchainTokenData[0]
        })
      ),
      // Includes the token twice, this will revert due to the return data being to long
      abi.encode(s_destFeeToken, s_destFeeToken, amount)
    );

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.InvalidDataLength.selector, 64, 96));

    s_offRamp.releaseOrMintTokens(srcTokenAmounts, MESSAGE_ROUTE, encodedSourceTokenData, offchainTokenData);
  }

  function test_releaseOrMintTokens_InvalidEVMAddress_Revert() public {
    Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();

    bytes[] memory offchainTokenData = new bytes[](srcTokenAmounts.length);
    bytes[] memory sourceTokenData = _getDefaultSourceTokenData(srcTokenAmounts);
    bytes memory wrongAddress = abi.encode(address(1000), address(10000), address(10000));

    sourceTokenData[0] = abi.encode(
      Internal.SourceTokenData({
        sourcePoolAddress: abi.encode(s_sourcePoolByToken[srcTokenAmounts[0].token]),
        destPoolAddress: wrongAddress,
        extraData: ""
      })
    );

    vm.expectRevert(abi.encodeWithSelector(Internal.InvalidEVMAddress.selector, wrongAddress));

    s_offRamp.releaseOrMintTokens(srcTokenAmounts, MESSAGE_ROUTE, sourceTokenData, offchainTokenData);
  }

  // TODO: re-add after ARL changes
  // function test_RateLimitErrors_Reverts() public {
  //   Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();

  //   bytes[] memory rateLimitErrors = new bytes[](5);
  //   rateLimitErrors[0] = abi.encodeWithSelector(RateLimiter.BucketOverfilled.selector);
  //   rateLimitErrors[1] =
  //     abi.encodeWithSelector(RateLimiter.AggregateValueMaxCapacityExceeded.selector, uint256(100), uint256(1000));
  //   rateLimitErrors[2] =
  //     abi.encodeWithSelector(RateLimiter.AggregateValueRateLimitReached.selector, uint256(42), 1, s_sourceTokens[0]);
  //   rateLimitErrors[3] = abi.encodeWithSelector(
  //     RateLimiter.TokenMaxCapacityExceeded.selector, uint256(100), uint256(1000), s_sourceTokens[0]
  //   );
  //   rateLimitErrors[4] =
  //     abi.encodeWithSelector(RateLimiter.TokenRateLimitReached.selector, uint256(42), 1, s_sourceTokens[0]);

  //   for (uint256 i = 0; i < rateLimitErrors.length; ++i) {
  //     s_maybeRevertingPool.setShouldRevert(rateLimitErrors[i]);

  //     vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.TokenHandlingError.selector, rateLimitErrors[i]));

  //     s_offRamp.releaseOrMintTokens(
  //       srcTokenAmounts,
  //       abi.encode(OWNER),
  //       OWNER,
  //       _getDefaultSourceTokenData(srcTokenAmounts),
  //       new bytes[](srcTokenAmounts.length)
  //     );
  //   }
  // }

  function test__releaseOrMintTokens_PoolIsNotAPool_Reverts() public {
    // The offRamp is a contract, but not a pool
    address fakePoolAddress = address(s_offRamp);

    bytes[] memory sourceTokenData = new bytes[](1);
    sourceTokenData[0] = abi.encode(
      Internal.SourceTokenData({
        sourcePoolAddress: abi.encode(fakePoolAddress),
        destPoolAddress: abi.encode(s_offRamp),
        extraData: ""
      })
    );

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.NotACompatiblePool.selector, fakePoolAddress));
    s_offRamp.releaseOrMintTokens(new Client.EVMTokenAmount[](1), MESSAGE_ROUTE, sourceTokenData, new bytes[](1));
  }

  function test__releaseOrMintTokens_PoolIsNotAContract_Reverts() public {
    address fakePoolAddress = makeAddr("Doesn't exist");

    bytes[] memory sourceTokenData = new bytes[](1);
    sourceTokenData[0] = abi.encode(
      Internal.SourceTokenData({
        sourcePoolAddress: abi.encode(fakePoolAddress),
        destPoolAddress: abi.encode(fakePoolAddress),
        extraData: ""
      })
    );

    vm.expectRevert(abi.encodeWithSelector(EVM2EVMMultiOffRamp.NotACompatiblePool.selector, fakePoolAddress));
    s_offRamp.releaseOrMintTokens(new Client.EVMTokenAmount[](1), MESSAGE_ROUTE, sourceTokenData, new bytes[](1));
  }

  function test_PriceNotFoundForToken_Reverts() public {
    // Set token price to 0
    s_priceRegistry.updatePrices(getSingleTokenPriceUpdateStruct(s_destFeeToken, 0));

    Client.EVMTokenAmount[] memory srcTokenAmounts = getCastedSourceEVMTokenAmountsWithZeroAmounts();
    uint256 amount1 = 100;
    srcTokenAmounts[0].amount = amount1;

    bytes[] memory offchainTokenData = new bytes[](srcTokenAmounts.length);
    offchainTokenData[0] = abi.encode(0x12345678);

    bytes[] memory sourceTokenData = _getDefaultSourceTokenData(srcTokenAmounts);

    vm.expectRevert(abi.encodeWithSelector(AggregateRateLimiter.PriceNotFoundForToken.selector, s_destFeeToken));

    s_offRamp.releaseOrMintTokens(srcTokenAmounts, MESSAGE_ROUTE, sourceTokenData, offchainTokenData);
  }

  /// forge-config: default.fuzz.runs = 32
  /// forge-config: ccip.fuzz.runs = 1024
  // Uint256 gives a good range of values to test, both inside and outside of the eth address space.
  function test_Fuzz__releaseOrMintTokens_AnyRevertIsCaught_Success(uint256 destPool) public {
    // Input 447301751254033913445893214690834296930546521452, which is 0x4E59B44847B379578588920CA78FBF26C0B4956C
    // triggers some Create2Deployer and causes it to fail
    vm.assume(destPool != 447301751254033913445893214690834296930546521452);
    bytes memory unusedVar = abi.encode(makeAddr("unused"));
    bytes[] memory sourceTokenData = new bytes[](1);
    sourceTokenData[0] = abi.encode(
      Internal.SourceTokenData({
        sourcePoolAddress: unusedVar,
        destPoolAddress: abi.encode(destPool),
        extraData: unusedVar
      })
    );

    try s_offRamp.releaseOrMintTokens(new Client.EVMTokenAmount[](1), MESSAGE_ROUTE, sourceTokenData, new bytes[](1)) {}
    catch (bytes memory reason) {
      // Any revert should be a TokenHandlingError, InvalidEVMAddress, InvalidDataLength or NoContract as those are caught by the offramp
      assertTrue(
        bytes4(reason) == EVM2EVMMultiOffRamp.TokenHandlingError.selector
          || bytes4(reason) == Internal.InvalidEVMAddress.selector
          || bytes4(reason) == EVM2EVMMultiOffRamp.InvalidDataLength.selector
          || bytes4(reason) == CallWithExactGas.NoContract.selector
          || bytes4(reason) == EVM2EVMMultiOffRamp.NotACompatiblePool.selector,
        "Expected TokenHandlingError or InvalidEVMAddress"
      );

      if (destPool > type(uint160).max) {
        assertEq(reason, abi.encodeWithSelector(Internal.InvalidEVMAddress.selector, abi.encode(destPool)));
      }
    }
  }
}

contract EVM2EVMMultiOffRamp_applySourceChainConfigUpdates is EVM2EVMMultiOffRampSetup {
  event SourceChainSelectorAdded(uint64 sourceChainSelector);
  event SourceChainConfigSet(uint64 indexed sourceChainSelector, EVM2EVMMultiOffRamp.SourceChainConfig sourceConfig);

  function test_ApplyZeroUpdates_Success() public {
    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](0);

    vm.recordLogs();
    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    // No logs emitted
    Vm.Log[] memory logEntries = vm.getRecordedLogs();
    assertEq(logEntries.length, 0);

    // assertEq(s_offRamp.getSourceChainSelectors().length, 0);
  }

  function test_AddNewChain_Success() public {
    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](1);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS
    });

    EVM2EVMMultiOffRamp.SourceChainConfig memory expectedSourceChainConfig = EVM2EVMMultiOffRamp.SourceChainConfig({
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS,
      metadataHash: s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, ON_RAMP_ADDRESS)
    });

    vm.expectEmit();
    emit SourceChainSelectorAdded(SOURCE_CHAIN_SELECTOR_1);

    vm.expectEmit();
    emit SourceChainConfigSet(SOURCE_CHAIN_SELECTOR_1, expectedSourceChainConfig);

    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    _assertSourceChainConfigEquality(s_offRamp.getSourceChainConfig(SOURCE_CHAIN_SELECTOR_1), expectedSourceChainConfig);

    // uint64[] memory resultSourceChainSelectors = s_offRamp.getSourceChainSelectors();
    // assertEq(resultSourceChainSelectors.length, 1);
    // assertEq(resultSourceChainSelectors[0], SOURCE_CHAIN_SELECTOR_1);
  }

  function test_ReplaceExistingChain_Success() public {
    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](1);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS
    });

    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    sourceChainConfigs[0].onRamp = address(uint160(ON_RAMP_ADDRESS) + 1);
    EVM2EVMMultiOffRamp.SourceChainConfig memory expectedSourceChainConfig = EVM2EVMMultiOffRamp.SourceChainConfig({
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: sourceChainConfigs[0].onRamp,
      metadataHash: s_offRamp.metadataHash(SOURCE_CHAIN_SELECTOR_1, sourceChainConfigs[0].onRamp)
    });

    vm.expectEmit();
    emit SourceChainConfigSet(SOURCE_CHAIN_SELECTOR_1, expectedSourceChainConfig);

    vm.recordLogs();
    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    // No log emitted for chain selector added (only for setting the config)
    Vm.Log[] memory logEntries = vm.getRecordedLogs();
    assertEq(logEntries.length, 1);

    _assertSourceChainConfigEquality(s_offRamp.getSourceChainConfig(SOURCE_CHAIN_SELECTOR_1), expectedSourceChainConfig);

    // uint64[] memory resultSourceChainSelectors = s_offRamp.getSourceChainSelectors();
    // assertEq(resultSourceChainSelectors.length, 1);
    // assertEq(resultSourceChainSelectors[0], SOURCE_CHAIN_SELECTOR_1);
  }

  function test_AddMultipleChains_Success() public {
    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](3);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: ON_RAMP_ADDRESS
    });
    sourceChainConfigs[1] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1 + 1,
      isEnabled: false,
      prevOffRamp: address(999),
      onRamp: address(uint160(ON_RAMP_ADDRESS) + 7)
    });
    sourceChainConfigs[2] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1 + 2,
      isEnabled: true,
      prevOffRamp: address(1000),
      onRamp: address(uint160(ON_RAMP_ADDRESS) + 42)
    });

    EVM2EVMMultiOffRamp.SourceChainConfig[] memory expectedSourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfig[](3);
    for (uint256 i = 0; i < 3; ++i) {
      expectedSourceChainConfigs[i] = EVM2EVMMultiOffRamp.SourceChainConfig({
        isEnabled: sourceChainConfigs[i].isEnabled,
        prevOffRamp: sourceChainConfigs[i].prevOffRamp,
        onRamp: sourceChainConfigs[i].onRamp,
        metadataHash: s_offRamp.metadataHash(sourceChainConfigs[i].sourceChainSelector, sourceChainConfigs[i].onRamp)
      });

      vm.expectEmit();
      emit SourceChainSelectorAdded(sourceChainConfigs[i].sourceChainSelector);

      vm.expectEmit();
      emit SourceChainConfigSet(sourceChainConfigs[i].sourceChainSelector, expectedSourceChainConfigs[i]);
    }

    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);

    // uint64[] memory resultSourceChainSelectors = s_offRamp.getSourceChainSelectors();
    // assertEq(resultSourceChainSelectors.length, 3);

    for (uint256 i = 0; i < 3; ++i) {
      _assertSourceChainConfigEquality(
        s_offRamp.getSourceChainConfig(sourceChainConfigs[i].sourceChainSelector), expectedSourceChainConfigs[i]
      );

      // assertEq(resultSourceChainSelectors[i], sourceChainConfigs[i].sourceChainSelector);
    }
  }

  function test_ZeroOnRampAddress_Revert() public {
    EVM2EVMMultiOffRamp.SourceChainConfigArgs[] memory sourceChainConfigs =
      new EVM2EVMMultiOffRamp.SourceChainConfigArgs[](1);
    sourceChainConfigs[0] = EVM2EVMMultiOffRamp.SourceChainConfigArgs({
      sourceChainSelector: SOURCE_CHAIN_SELECTOR_1,
      isEnabled: true,
      prevOffRamp: address(0),
      onRamp: address(0)
    });

    vm.expectRevert(EVM2EVMMultiOffRamp.ZeroAddressNotAllowed.selector);
    s_offRamp.applySourceChainConfigUpdates(sourceChainConfigs);
  }
}