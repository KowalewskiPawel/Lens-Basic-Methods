// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.10;

import {IERC721Time} from '../core/base/IERC721Time.sol';
import {ILensHub} from '../interfaces/ILensHub.sol';
import {DataTypes} from '../libraries/DataTypes.sol';
import {Events} from '../libraries/Events.sol';
import {Errors} from '../libraries/Errors.sol';

/**
 * @notice This is a peripheral contract that acts as a source of truth for profile metadata and allows
 * for users to emit an event demonstrating whether or not they explicitly want a follow to be shown.
 *
 * @dev This is useful because it allows clients to filter out follow NFTs that were transferred to
 * a recipient by another user (i.e. Not a mint) and not register them as "following" unless
 * the recipient explicitly toggles the follow here.
 */
contract LensPeripheryDataProvider {
    string public constant NAME = 'LensPeripheryDataProvider';
    bytes32 internal constant EIP712_REVISION_HASH = keccak256('1');
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
        );
    bytes32 internal constant TOGGLE_FOLLOW_WITH_SIG_TYPEHASH =
        keccak256(
            'ToggleFollowWithSig(uint256[] profileIds,bool[] enables,uint256 nonce,uint256 deadline)'
        );
    bytes32 internal constant SET_PROFILE_METADATA_WITH_SIG_TYPEHASH =
        keccak256(
            'SetProfileMetadataWithSig(uint256 profileId,string metadata,uint256 nonce,uint256 deadline)'
        );

    ILensHub public immutable HUB;

    mapping(address => uint256) public sigNonces;

    mapping(address => mapping(uint256 => string)) internal _metadataByProfileByOwner;

    constructor(ILensHub hub) {
        HUB = hub;
    }

    /**
     * @notice Sets profile metadata for a profile owner as a dispatcher.
     *
     * @param profileId The profile ID to set the metadata for.
     * @param metadata The metadata string to set for the profile and owner.
     */
    function dispatcherSetProfileMetadata(uint256 profileId, string calldata metadata) external {
        address owner = IERC721Time(address(HUB)).ownerOf(profileId);
        if (msg.sender == HUB.getDispatcher(profileId)) {
            _setProfileMetadata(owner, profileId, metadata);
        } else {
            revert Errors.NotDispatcher();
        }
    }

    /**
     * @notice Sets the profile metadata for a given profile when owned by the message sender.
     *
     * @param profileId The profile ID to set the metadata for.
     * @param metadata The metadata string to set for the profile and message sender.
     */
    function setProfileMetadata(uint256 profileId, string calldata metadata) external {
        _setProfileMetadata(msg.sender, profileId, metadata);
    }

    /**
     * @notice Sets the profile metadata for a given profile and user via signature with the specified parameters.
     *
     * @param vars A SetProfileMetadataWithSigData struct containingthe regular parameters as well as the user address
     * and an EIP712Signature struct.
     */
    function setProfileMetadataWithSig(DataTypes.SetProfileMetadataWithSigData calldata vars)
        external
    {
        _validateRecoveredAddress(
            _calculateDigest(
                keccak256(
                    abi.encode(
                        SET_PROFILE_METADATA_WITH_SIG_TYPEHASH,
                        vars.profileId,
                        keccak256(bytes(vars.metadata)),
                        sigNonces[vars.user]++,
                        vars.sig.deadline
                    )
                )
            ),
            vars.user,
            vars.sig
        );
        _setProfileMetadata(vars.user, vars.profileId, vars.metadata);
    }

    /**
     * @notice Toggle Follows on the given profiles, emiting toggle event for each FollowNFT.
     *
     * NOTE: `profileIds`, `followNFTIds` and `enables` arrays must be of the same length.
     *
     * @param profileIds The token ID array of the profiles.
     * @param enables The array of booleans to enable/disable follows.
     */
    function toggleFollow(uint256[] calldata profileIds, bool[] calldata enables) external {
        _toggleFollow(msg.sender, profileIds, enables);
    }

    /**
     * @notice Toggle Follows a given profiles via signature with the specified parameters.
     *
     * @param vars A ToggleFollowWithSigData struct containing the regular parameters as well as the signing follower's address
     * and an EIP712Signature struct.
     */
    function toggleFollowWithSig(DataTypes.ToggleFollowWithSigData calldata vars) external {
        _validateRecoveredAddress(
            _calculateDigest(
                keccak256(
                    abi.encode(
                        TOGGLE_FOLLOW_WITH_SIG_TYPEHASH,
                        keccak256(abi.encodePacked(vars.profileIds)),
                        keccak256(abi.encodePacked(vars.enables)),
                        sigNonces[vars.follower]++,
                        vars.sig.deadline
                    )
                )
            ),
            vars.follower,
            vars.sig
        );
        _toggleFollow(vars.follower, vars.profileIds, vars.enables);
    }

    function getProfileMetadata(uint256 profileId) external view returns (string memory) {
        address owner = IERC721Time(address(HUB)).ownerOf(profileId);
        return _metadataByProfileByOwner[owner][profileId];
    }

    function getProfileMetadataByOwner(address owner, uint256 profileId)
        external
        view
        returns (string memory)
    {
        return _metadataByProfileByOwner[owner][profileId];
    }

    function _setProfileMetadata(
        address owner,
        uint256 profileId,
        string calldata metadata
    ) internal {
        _metadataByProfileByOwner[owner][profileId] = metadata;
    }

    function _toggleFollow(
        address follower,
        uint256[] calldata profileIds,
        bool[] calldata enables
    ) internal {
        if (profileIds.length != enables.length) revert Errors.ArrayMismatch();
        for (uint256 i = 0; i < profileIds.length; ++i) {
            address followNFT = HUB.getFollowNFT(profileIds[i]);
            if (followNFT == address(0)) revert Errors.FollowInvalid();
            if (!IERC721Time(address(HUB)).exists(profileIds[i])) revert Errors.TokenDoesNotExist();
            if (IERC721Time(followNFT).balanceOf(follower) == 0) revert Errors.FollowInvalid();
        }
        emit Events.FollowsToggled(follower, profileIds, enables, block.timestamp);
    }

    /**
     * @dev Wrapper for ecrecover to reduce code size, used in meta-tx specific functions.
     */
    function _validateRecoveredAddress(
        bytes32 digest,
        address expectedAddress,
        DataTypes.EIP712Signature memory sig
    ) internal view {
        if (sig.deadline < block.timestamp) revert Errors.SignatureExpired();
        address recoveredAddress = ecrecover(digest, sig.v, sig.r, sig.s);
        if (recoveredAddress == address(0) || recoveredAddress != expectedAddress)
            revert Errors.SignatureInvalid();
    }

    /**
     * @dev Calculates EIP712 DOMAIN_SEPARATOR based on the current contract and chain ID.
     */
    function _calculateDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes(NAME)),
                    EIP712_REVISION_HASH,
                    block.chainid,
                    address(this)
                )
            );
    }

    /**
     * @dev Calculates EIP712 digest based on the current DOMAIN_SEPARATOR.
     *
     * @param hashedMessage The message hash from which the digest should be calculated.
     *
     * @return bytes32 A 32-byte output representing the EIP712 digest.
     */
    function _calculateDigest(bytes32 hashedMessage) internal view returns (bytes32) {
        bytes32 digest;
        unchecked {
            digest = keccak256(
                abi.encodePacked('\x19\x01', _calculateDomainSeparator(), hashedMessage)
            );
        }
        return digest;
    }
}
