// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ITypeAndVersion} from "../shared/interfaces/ITypeAndVersion.sol";
import {IMultiCommitStore} from "./interfaces/IMultiCommitStore.sol";
import {IPriceRegistry} from "./interfaces/IPriceRegistry.sol";
import {IRMN} from "./interfaces/IRMN.sol";

import {Internal} from "./libraries/Internal.sol";

import {MerkleMultiProof} from "./libraries/MerkleMultiProof.sol";
import {OCR2Base} from "./ocr/OCR2Base.sol";

contract MultiCommitStore is IMultiCommitStore, ITypeAndVersion, OCR2Base {
  error StaleReport();
  error PausedError();
  error InvalidInterval(uint64 sourceChainSelector, Interval interval);
  error InvalidRoot();
  error InvalidCommitStoreConfig();
  error InvalidSourceChainConfig(uint64 sourceChainSelector);
  error BadARMSignal();
  error CursedByRMN(uint64 sourceChainSelector);
  error RootAlreadyCommitted(uint64 sourceChainSelector, bytes32 merkleRoot);
  error SourceChainNotEnabled(uint64 chainSelector);

  event Paused(address account);
  event Unpaused(address account);
  /// @dev RMN depends on this event, if changing, please notify the RMN maintainers.
  event ReportAccepted(CommitReport report);
  event ConfigSet(StaticConfig staticConfig, DynamicConfig dynamicConfig);
  event RootRemoved(bytes32 root);
  event SourceChainConfigUpdated(uint64 indexed sourceChainSelector, SourceChainConfig sourceChainConfig);

  /// @notice Static commit store config
  /// @dev RMN depends on this struct, if changing, please notify the RMN maintainers.
  struct StaticConfig {
    uint64 chainSelector; // ───────╮  Destination chainSelector
    address rmnProxy; // ───────────╯ RMN proxy address
  }

  /// @notice Dynamic commit store config
  struct DynamicConfig {
    address priceRegistry; // Price registry address on the local chain
  }

  /// @dev Struct to hold the configs for a source chain, same as SourceChainConfig but with the sourceChainSelector
  /// so that an array of these can be passed in the constructor and the applySourceChainConfigUpdates function.
  struct SourceChainConfigArgs {
    uint64 sourceChainSelector; // ──╮ The source chain selector
    bool isEnabled; //               | Whether the source chain is enabled
    uint64 minSeqNr; // ─────────────╯ The min sequence number expected for future messages
    address onRamp; // The onRamp address on the source chain
  }

  /// @notice a sequenceNumber interval
  /// @dev RMN depends on this struct, if changing, please notify the RMN maintainers.
  struct Interval {
    uint64 min; // ───╮ Minimum sequence number, inclusive
    uint64 max; // ───╯ Maximum sequence number, inclusive
  }

  /// @dev Struct to hold a merkle root and an interval for a source chain so that an array of these can be passed in the CommitReport.
  struct MerkleRoot {
    uint64 sourceChainSelector;
    Interval interval;
    bytes32 merkleRoot;
  }

  /// @notice Report that is committed by the observing DON at the committing phase
  /// @dev RMN depends on this struct, if changing, please notify the RMN maintainers.
  struct CommitReport {
    Internal.PriceUpdates priceUpdates;
    MerkleRoot[] merkleRoots;
  }

  /// @dev Struct to hold a merkle root for a source chain so that an array of these can be passed in the resetUblessedRoots function.
  struct UnblessedRoot {
    uint64 sourceChainSelector;
    bytes32 merkleRoot;
  }

  // STATIC CONFIG
  string public constant override typeAndVersion = "MultiCommitStore 1.6.0-dev";
  // Chain ID of this chain
  uint64 internal immutable i_chainSelector;
  // The address of the rmn proxy
  address internal immutable i_rmnProxy;

  // DYNAMIC CONFIG
  // The dynamic commitStore config
  DynamicConfig internal s_dynamicConfig;

  // STATE
  /// @dev The epoch and round of the last report
  uint40 private s_latestPriceEpochAndRound;
  /// @dev Whether this OnRamp is paused or not
  bool private s_paused = false;
  // The source chain specific config
  mapping(uint64 sourceChainSelector => SourceChainConfig sourceChainConfig) private s_sourceChainConfigs;
  // sourceChainSelector => merkleRoot => timestamp when received
  mapping(uint64 sourceChainSelector => mapping(bytes32 merkleRoot => uint256 timestamp)) private s_roots;

  /// @param staticConfig Containing the static part of the commitStore config
  /// @param sourceChainConfigs An array of source chain specific configs
  /// @dev When instantiating OCR2Base we set UNIQUE_REPORTS to false, which means
  /// that we do not require 2f+1 signatures on a report, only f+1 to save gas. 2f+1 is required
  /// only if one must strictly ensure that for a given round there is only one valid report ever generated by
  /// the DON. In our case additional valid reports (i.e. approved by >= f+1 oracles) are not a problem, as they will
  /// will either be ignored (reverted as an invalid interval) or will be accepted as an additional valid price update.
  constructor(StaticConfig memory staticConfig, SourceChainConfigArgs[] memory sourceChainConfigs) OCR2Base(false) {
    if (staticConfig.chainSelector == 0 || staticConfig.rmnProxy == address(0)) {
      revert InvalidCommitStoreConfig();
    }

    i_chainSelector = staticConfig.chainSelector;
    i_rmnProxy = staticConfig.rmnProxy;

    _applySourceChainConfigUpdates(sourceChainConfigs);
  }

  // ================================================================
  // │                        Verification                          │
  // ================================================================

  /// @notice Returns the onRamp address for a given source chain selector.
  /// @param sourceChainSelector The source chain selector.
  /// @return the onRamp address.
  function getOnRamp(uint64 sourceChainSelector) external view returns (address) {
    return s_sourceChainConfigs[sourceChainSelector].onRamp;
  }

  /// @notice Returns the epoch and round of the last price update.
  /// @return the latest price epoch and round.
  function getLatestPriceEpochAndRound() public view returns (uint64) {
    return s_latestPriceEpochAndRound;
  }

  /// @notice Sets the latest epoch and round for price update.
  /// @param latestPriceEpochAndRound The new epoch and round for prices.
  function setLatestPriceEpochAndRound(uint40 latestPriceEpochAndRound) external onlyOwner {
    s_latestPriceEpochAndRound = latestPriceEpochAndRound;
  }

  /// @notice Returns the timestamp of a potentially previously committed merkle root.
  /// If the root was never committed 0 will be returned.
  /// @param sourceChainSelector The source chain selector.
  /// @param root The merkle root to check the commit status for.
  /// @return the timestamp of the committed root or zero in the case that it was never
  /// committed.
  function getMerkleRoot(uint64 sourceChainSelector, bytes32 root) external view returns (uint256) {
    return s_roots[sourceChainSelector][root];
  }

  /// @notice Returns if a root is blessed or not.
  /// @param root The merkle root to check the blessing status for.
  /// @return whether the root is blessed or not.
  function isBlessed(bytes32 root) public view returns (bool) {
    // TODO: update RMN to also consider the source chain selector for blessing
    return IRMN(i_rmnProxy).isBlessed(IRMN.TaggedRoot({commitStore: address(this), root: root}));
  }

  /// @notice Used by the owner in case an invalid sequence of roots has been
  /// posted and needs to be removed. The interval in the report is trusted.
  /// @param rootToReset The roots that will be reset. This function will only
  /// reset roots that are not blessed.
  function resetUnblessedRoots(UnblessedRoot[] calldata rootToReset) external onlyOwner {
    for (uint256 i = 0; i < rootToReset.length; ++i) {
      UnblessedRoot memory root = rootToReset[i];
      if (!isBlessed(root.merkleRoot)) {
        delete s_roots[root.sourceChainSelector][root.merkleRoot];
        emit RootRemoved(root.merkleRoot);
      }
    }
  }

  /// @inheritdoc IMultiCommitStore
  function verify(
    uint64 sourceChainSelector,
    bytes32[] calldata hashedLeaves,
    bytes32[] calldata proofs,
    uint256 proofFlagBits
  ) external view override whenNotPaused returns (uint256 timestamp) {
    bytes32 root = MerkleMultiProof.merkleRoot(hashedLeaves, proofs, proofFlagBits);
    // Only return non-zero if present and blessed.
    if (!isBlessed(root)) {
      return 0;
    }
    return s_roots[sourceChainSelector][root];
  }

  /// @inheritdoc OCR2Base
  /// @dev A commitReport can have two distinct parts (batched together to amortize the cost of checking sigs):
  /// 1. Price updates
  /// 2. A merkle root and sequence number interval
  /// Both have their own, separate, staleness checks, with price updates using the epoch and round
  /// number of the latest price update. The merkle root checks for staleness based on the seqNums.
  /// They need to be separate because a price report for round t+2 might be included before a report
  /// containing a merkle root for round t+1. This merkle root report for round t+1 is still valid
  /// and should not be rejected. When a report with a stale root but valid price updates is submitted,
  /// we are OK to revert to preserve the invariant that we always revert on invalid sequence number ranges.
  /// If that happens, prices will be updates in later rounds.
  function _report(bytes calldata encodedReport, uint40 epochAndRound) internal override whenNotPaused {
    CommitReport memory report = abi.decode(encodedReport, (CommitReport));

    // Check if the report contains price updates
    if (report.priceUpdates.tokenPriceUpdates.length > 0 || report.priceUpdates.gasPriceUpdates.length > 0) {
      // Check for price staleness based on the epoch and round
      if (s_latestPriceEpochAndRound < epochAndRound) {
        // If prices are not stale, update the latest epoch and round
        s_latestPriceEpochAndRound = epochAndRound;
        // And update the prices in the price registry
        IPriceRegistry(s_dynamicConfig.priceRegistry).updatePrices(report.priceUpdates);

        // If there is no root, the report only contained fee updated and
        // we return to not revert on the empty root check below.
        if (report.merkleRoots.length == 0) return;
      } else {
        // If prices are stale and the report doesn't contain a root, this report
        // does not have any valid information and we revert.
        // If it does contain a merkle root, continue to the root checking section.
        if (report.merkleRoots.length == 0) revert StaleReport();
      }
    }

    for (uint256 i = 0; i < report.merkleRoots.length; ++i) {
      MerkleRoot memory root = report.merkleRoots[i];
      uint64 sourceChainSelector = root.sourceChainSelector;

      if (IRMN(i_rmnProxy).isCursed(bytes16(uint128(sourceChainSelector)))) revert CursedByRMN(sourceChainSelector);

      SourceChainConfig storage sourceChainConfig = s_sourceChainConfigs[sourceChainSelector];

      if (!sourceChainConfig.isEnabled) revert SourceChainNotEnabled(sourceChainSelector);
      // If we reached this section, the report should contain a valid root
      if (sourceChainConfig.minSeqNr != root.interval.min || root.interval.min > root.interval.max) {
        revert InvalidInterval(root.sourceChainSelector, root.interval);
      }

      // TODO: confirm how RMN offchain blessing impacts commit report
      if (root.merkleRoot == bytes32(0)) revert InvalidRoot();
      // Disallow duplicate roots as that would reset the timestamp and
      // delay potential manual execution.
      if (s_roots[root.sourceChainSelector][root.merkleRoot] != 0) {
        revert RootAlreadyCommitted(root.sourceChainSelector, root.merkleRoot);
      }

      sourceChainConfig.minSeqNr = root.interval.max + 1;
      s_roots[root.sourceChainSelector][root.merkleRoot] = block.timestamp;
    }

    emit ReportAccepted(report);
  }

  // ================================================================
  // │                           Config                             │
  // ================================================================

  /// @notice Returns the static commit store config.
  /// @dev RMN depends on this function, if changing, please notify the RMN maintainers.
  /// @return the configuration.
  function getStaticConfig() external view returns (StaticConfig memory) {
    return StaticConfig({chainSelector: i_chainSelector, rmnProxy: i_rmnProxy});
  }

  /// @notice Returns the dynamic commit store config.
  /// @return the configuration.
  function getDynamicConfig() external view returns (DynamicConfig memory) {
    return s_dynamicConfig;
  }

  /// @notice Sets the dynamic config. This function is called during `setOCR2Config` flow
  function _beforeSetConfig(bytes memory onchainConfig) internal override {
    DynamicConfig memory dynamicConfig = abi.decode(onchainConfig, (DynamicConfig));

    if (dynamicConfig.priceRegistry == address(0)) revert InvalidCommitStoreConfig();

    s_dynamicConfig = dynamicConfig;
    // When the OCR config changes, we reset the price epoch and round
    // since epoch and rounds are scoped per config digest.
    // Note that s_minSeqNr/roots do not need to be reset as the roots persist
    // across reconfigurations and are de-duplicated separately.
    s_latestPriceEpochAndRound = 0;

    emit ConfigSet(StaticConfig({chainSelector: i_chainSelector, rmnProxy: i_rmnProxy}), dynamicConfig);
  }

  /// @notice Returns the config for a source chain.
  /// @param sourceChainSelector The source chain selector.
  /// @return The source chain specific config.
  function getSourceChainConfig(uint64 sourceChainSelector) external view returns (SourceChainConfig memory) {
    return s_sourceChainConfigs[sourceChainSelector];
  }

  /// @notice Updates the source chain specific config.
  /// @param sourceChainConfigs The source chain specific config updates.
  function applySourceChainConfigUpdates(SourceChainConfigArgs[] memory sourceChainConfigs) external onlyOwner {
    _applySourceChainConfigUpdates(sourceChainConfigs);
  }

  /// @notice Internal version applySourceChainConfigUpdates.
  /// Note: This function is kept multi purpose for now (adding/updating lanes + enabling/disabling lanes) to reduce contract size in anticipation of
  /// merging this contract with the EVM2EVMMultiOffRamp. This will be revisited in the merging PR.
  function _applySourceChainConfigUpdates(SourceChainConfigArgs[] memory sourceChainConfigs) internal onlyOwner {
    for (uint256 i = 0; i < sourceChainConfigs.length; ++i) {
      SourceChainConfigArgs memory sourceChainConfig = sourceChainConfigs[i];
      if (sourceChainConfig.onRamp == address(0) || sourceChainConfig.sourceChainSelector == 0) {
        revert InvalidSourceChainConfig(sourceChainConfig.sourceChainSelector);
      }

      address onRamp = s_sourceChainConfigs[sourceChainConfig.sourceChainSelector].onRamp;

      if (onRamp == address(0)) {
        // If onRamp is not set, then minSeqNr should be 1.
        if (sourceChainConfig.minSeqNr != 1) revert InvalidSourceChainConfig(sourceChainConfig.sourceChainSelector);
      } else {
        // If onRamp is already set, it should not be updated.
        if (sourceChainConfig.onRamp != onRamp) revert InvalidSourceChainConfig(sourceChainConfig.sourceChainSelector);
      }

      SourceChainConfig memory newSourceChainConfig = SourceChainConfig({
        isEnabled: sourceChainConfig.isEnabled,
        minSeqNr: sourceChainConfig.minSeqNr,
        onRamp: sourceChainConfig.onRamp
      });

      s_sourceChainConfigs[sourceChainConfig.sourceChainSelector] = newSourceChainConfig;

      emit SourceChainConfigUpdated(sourceChainConfig.sourceChainSelector, newSourceChainConfig);
    }
  }

  // ================================================================
  // │                        Access and RMN                        │
  // ================================================================

  /// @notice Single function to check the status of the commitStore.
  function isUnpausedAndNotCursed(uint64 sourceChainSelector) external view returns (bool) {
    return !IRMN(i_rmnProxy).isCursed(bytes16(uint128(sourceChainSelector))) && !s_paused;
  }

  /// @notice Modifier to make a function callable only when the contract is not paused.
  modifier whenNotPaused() {
    if (paused()) revert PausedError();
    _;
  }

  /// @notice Returns true if the contract is paused, and false otherwise.
  function paused() public view returns (bool) {
    return s_paused;
  }

  /// @notice Pause the contract
  /// @dev only callable by the owner
  function pause() external onlyOwner {
    s_paused = true;
    emit Paused(msg.sender);
  }

  /// @notice Unpause the contract
  /// @dev only callable by the owner
  function unpause() external onlyOwner {
    s_paused = false;
    emit Unpaused(msg.sender);
  }
}
