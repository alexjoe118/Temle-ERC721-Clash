// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

import "./Camel.sol";

contract Memeverse is Ownable, IERC721Receiver, Pausable {
    // Maximum alpha score for a Camel
    uint8 public constant MAX_ALPHA = 8;

    // Struct to store a stake's token, earning values, owner
    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    event TokenStaked(address owner, uint256 tokenId, uint256 value);
    event BanditsClaimed(uint256 tokenId, uint256 earned, bool unstaked);
    event CamelsClaimed(uint256 tokenId, uint256 earned, bool unstaked);

    Camel camel; // Reference to the Camel NFT contract
    GOLD gold; // Reference to the $GOLD contract

    mapping(uint256 => Stake) public memeverse;    // tokenId => stake
    mapping(uint256 => Stake[]) public gym;        // alpha => all Camel stakes with that alpha
    mapping(uint256 => uint256) public gymIndices; // Camel => location of Camel in Gym

    uint256 public totalAlphaStaked = 0;
    uint256 public unaccountedRewards = 0; // rewards distributed when no Camels are staked
    uint256 public goldPerAlpha = 0;       // amount of $GOLD due for each alpha point staked

    uint256 public constant DAILY_GOLD_RATE = 10000 ether; // Bandits earn 10000 $GOLD per day
    uint256 public constant MINIMUM_TO_EXIT = 2 days;      // Bandits must have 2 days worth of $GOLD to unstake
    uint256 public constant GOLD_CLAIM_TAX_PERCENTAGE = 20; // Camels take a 20% tax on all $WOOL claimed
    uint256 public constant MAXIMUM_GLOBAL_GOLD = 2400000000 ether; // only ever ~2.4b $GOLD earned via staking

    uint256 public totalGoldEarned;
    uint256 public totalBanditsStaked;
    uint256 public lastClaimTimestamp; // the last time $GOLD was claimed

    // Emergency rescue to allow unstaking without any checks but without $GOLD
    bool public rescueEnabled = false;

    /**
     * @param _camel: reference to the camel NFT contract
     * @param _gold: reference to the $GOLD token
     */
    constructor(address _camel, address _gold) {
        camel = Camel(_camel);
        gold = GOLD(_gold);
    }

    /** STAKING */

    /**
     * adds Bandits to the Memeverse and Camels to the gym
     * @param account: the address of the staker
     * @param tokenIds: the IDs of the Bandits and Camels to stake
     */
    function addManyToMemeverseAndGym(address account, uint16[] calldata tokenIds) external {
        require(
            account == _msgSender() || _msgSender() == address(camel),
            "Keep your tokens."
        );
        require(tx.origin == _msgSender());

        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(camel.totalSupply() >= tokenIds[i] + camel.MAX_PER_MINT()); // ensure not in buffer
            if (_msgSender() != address(camel)) {
                // Skip this step if mint + stake
                require(
                    camel.ownerOf(tokenIds[i]) == _msgSender(),
                    "This is not your token!"
                );
                camel.transferFrom(_msgSender(), address(this), tokenIds[i]);
            } else if (tokenIds[i] == 0) {
                continue; // There may be gaps in the array for stolen tokens
            }
            if (isCamel(tokenIds[i])) _addBanditToMemeverse(account, tokenIds[i]);
            else _addCamelToGym(account, tokenIds[i]);
        }
    }

    // ** INTERNAL * //

    /**
     * Adds a single Bandit to the Memeverse
     * @param account: the address of the staker
     * @param tokenId: the ID of the Bandit to add to the Memeverse
     */
    function _addBanditToMemeverse(address account, uint256 tokenId) internal whenNotPaused _updateEarnings{
        memeverse[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });
        totalBanditsStaked += 1;
        emit TokenStaked(account, tokenId, block.timestamp);
    }

    /**
     * adds a single Camel to the Gym
     * @param account the address of the staker
     * @param tokenId the ID of the Camel to add to the gym
     */
    function _addCamelToGym(address account, uint256 tokenId) internal {
        uint256 alpha = _alphaForCamel(tokenId);
        totalAlphaStaked += alpha; // Portion of earnings ranges from 8 to 5
        gymIndices[tokenId] = gym[alpha].length; // Store location of the Camel in the gym
        gym[alpha].push(
            Stake({
                owner: account,
                tokenId: uint16(tokenId),
                value: uint80(goldPerAlpha)
            })
        );
        emit TokenStaked(account, tokenId, goldPerAlpha);
    }

    /** CLAIMING / UNSTAKING */

    /**
     * Claim $GOLD earnings and optionally unstake tokens from the Memeverse/gym.
     * Bandit must have 2 days worth of unclaimed $GOLD to be unstaked.
     * @param tokenIds: the IDs of the tokens to claim earnings from
     * @param unstake: if should unstake all of the tokens listed in tokenIds
     */
    function claimManyFromMemeverseAndGym(uint16[] calldata tokenIds, bool unstake)
        external
        whenNotPaused
        _updateEarnings
    {
        require(tx.origin == _msgSender());
        uint256 owed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (isCamel(tokenIds[i]))
                owed += _claimBanditFromMemeverse(tokenIds[i], unstake);
            else owed += _claimCamelFromGym(tokenIds[i], unstake);
        }
        if (owed == 0) return;
        gold.mint(_msgSender(), owed);
    }

    // ** INTERNAL * //

    /**
     * Claim $GOLD earnings for a single Bandit and optionally unstake it.
     * If not unstaking, pay 20% tax to the staked Camels.
     * If unstaking, there is a 50% chance all $GOLD is stolen.
     * @param tokenId: the ID of the Bandit to claim earnings from
     * @param unstake: whether or not to unstake the Bandit
     * owed: the amount of $GOLD claimed
     */
    function _claimBanditFromMemeverse(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
        Stake memory stake = memeverse[tokenId];

        require(stake.owner == _msgSender(), "Not yours to take!");
        require(
            !(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT),
            "You have not met the minimum to exit."
        );

        if (totalGoldEarned < MAXIMUM_GLOBAL_GOLD) {
            owed = ((block.timestamp - stake.value) * DAILY_GOLD_RATE) / 1 days;
        } else if (stake.value > lastClaimTimestamp) {
            owed = 0; // $GOLD production stopped already
        } else {
            owed =
                ((lastClaimTimestamp - stake.value) * DAILY_GOLD_RATE) /
                1 days; // stop earning additional $GOLD if it's all been earned
        }

        if (unstake) {
            if (random(tokenId) & 1 == 1) {
                // 50% chance of all $GOLD stolen
                _payCamelTax(owed);
                owed = 0;
            }

            totalBanditsStaked -= 1;
            camel.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Bandits
            delete memeverse[tokenId];
        } else {
            _payCamelTax((owed * GOLD_CLAIM_TAX_PERCENTAGE) / 100); // percentage tax to staked Camels
            owed = (owed * (100 - GOLD_CLAIM_TAX_PERCENTAGE)) / 100; // remainder goes to Bandit owner

            memeverse[tokenId] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(block.timestamp)
            }); // reset stake
        }

        emit BanditsClaimed(tokenId, owed, unstake);
    }

    /**
     * Claim $GOLD earnings for a single Camel and optionally unstake it.
     * Camels earn $GOLD proportional to their alpha rank.
     * @param tokenId: the ID of the Camel to claim earnings from
     * @param unstake: whether or not to unstake the Camel
     * owed: the amount of $GOLD claimed
     */
    function _claimCamelFromGym(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
        require(camel.ownerOf(tokenId) == address(this), "Camel isn't in the gym."
        );

        uint256 alpha = _alphaForCamel(tokenId);
        Stake memory stake = gym[alpha][gymIndices[tokenId]];
        require(stake.owner == _msgSender(), "Not yours to take!");
        owed = (alpha) * (goldPerAlpha - stake.value); // calculate portion of tokens based on Alpha
        if (unstake) {
            totalAlphaStaked -= alpha; // remove alpha from total staked

            Stake memory lastStake = gym[alpha][gym[alpha].length - 1];
            gym[alpha][gymIndices[tokenId]] = lastStake; // shuffle last Camel to current position
            gymIndices[lastStake.tokenId] = gymIndices[tokenId];
            gym[alpha].pop(); // remove duplicate
            delete gymIndices[tokenId]; // delete previous mapping

            camel.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Camel
        } else {
            gym[alpha][gymIndices[tokenId]] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(goldPerAlpha)
            }); // reset stake
        }

        emit CamelsClaimed(tokenId, owed, unstake);
    }

    /**
     * Emergency measure to unstake tokens.
     * @param tokenIds: the IDs of the tokens to claim earnings from
     */
    function rescue(uint256[] calldata tokenIds) external {
        require(rescueEnabled, "RESCUE DISABLED");
        require(tx.origin == _msgSender());

        uint256 tokenId;
        Stake memory stake;
        Stake memory lastStake;
        uint256 alpha;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenId = tokenIds[i];

            if (isCamel(tokenId)) {
                stake = memeverse[tokenId];
                require(stake.owner == _msgSender(), "Not yours to take!");

                delete memeverse[tokenId];
                totalBanditsStaked -= 1;

                camel.safeTransferFrom(
                    address(this),
                    _msgSender(),
                    tokenId,
                    ""
                ); // send back Bandits

                emit BanditsClaimed(tokenId, 0, true);
            } else {
                alpha = _alphaForCamel(tokenId);
                stake = gym[alpha][gymIndices[tokenId]];

                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");

                totalAlphaStaked -= alpha; // remove alpha from total staked
                lastStake = gym[alpha][gym[alpha].length - 1];
                gym[alpha][gymIndices[tokenId]] = lastStake; // shuffle last Camel to current position
                gymIndices[lastStake.tokenId] = gymIndices[tokenId];
                gym[alpha].pop(); // remove duplicate
                delete gymIndices[tokenId]; // delete previous mapping

                camel.safeTransferFrom(
                    address(this),
                    _msgSender(),
                    tokenId,
                    ""
                ); // send back Camel

                emit CamelsClaimed(tokenId, 0, true);
            }
        }
    }

    /** ACCOUNTING */

    /**
     * add $GOLD to claimable pot for the gym
     * @param amount $GOLD to add to the pot
     */
    function _payCamelTax(uint256 amount) internal {
        if (totalAlphaStaked == 0) {      // if there are 0 staked Camels
            unaccountedRewards += amount; // keep track of $GOLD due to Camels
            return;
        }
        // make sure to include any unaccounted $GOLD
        goldPerAlpha += (amount + unaccountedRewards) / totalAlphaStaked;
        unaccountedRewards = 0;
    }

    /**
     * tracks $GOLD earnings to ensure it stops once 2.4 billion is passed
     */
    modifier _updateEarnings() {
        if (totalGoldEarned < MAXIMUM_GLOBAL_GOLD) {
            totalGoldEarned +=
                ((block.timestamp - lastClaimTimestamp) *
                    totalBanditsStaked *
                    DAILY_GOLD_RATE) /
                1 days;
            lastClaimTimestamp = block.timestamp;
        }
        _;
    }

    /** ADMIN */

    /**
     * Allows owner to enable "rescue mode".
     * Simplifies accounting, prioritizes tokens out in emergency.
     */
    function setRescueEnabled(bool _enabled) external onlyOwner {
        rescueEnabled = _enabled;
    }

    /**
     * Enables owner to pause/unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

    /** READ ONLY */

    /**
     * Checks if a token is a Bandit
     * @param tokenId: the ID of the token to check
     */
    function isCamel(uint256 tokenId) public view returns (bool _isCamel) {
        ICamel.CamelBandit memory iCamelBandit = camel.getTokenTraits(tokenId);
        return iCamelBandit.isCamel;
    }

    /**
     * Gets the alpha score for a Camel
     * @param tokenId: the ID of the Camel to get the alpha score for
     * @return the alpha score of the Camel (5-8)
     */
    function _alphaForCamel(uint256 tokenId) internal view returns (uint8) {
        ICamel.CamelBandit memory iCamelBandit = camel.getTokenTraits(tokenId);
        return MAX_ALPHA - iCamelBandit.alphaIndex; // alpha index is 0-3
    }

    /**
    * generates a pseudorandom number
    * @param seed a value ensure different outcomes for different sources in the same block
    * @return a pseudorandom value
    */
    function random(uint256 seed) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
        tx.origin,
        blockhash(block.number - 1),
        block.timestamp,
        seed
        )));
    }

    /**
     * Chooses a random Camel thief when a newly minted token is stolen.
     * @param seed: a random value to choose a Camel from
     * @return the owner of the randomly selected Camel thief
     */
    function randomBanditOwner(uint256 seed) external view returns (address) {
        require(address(msg.sender) == address(camel));

        if (totalAlphaStaked == 0) return address(0x0); // check if there are any staked Camels

        // Choose a value from 0 to totalAlphaStaked
        uint256 bucket = (seed & 0xFFFFFFFF) % totalAlphaStaked;
        uint256 cumulative;
        seed >>= 32;

        // Loop through each bucket of Camels with the same alpha score
        for (uint256 i = MAX_ALPHA - 3; i <= MAX_ALPHA; i++) {
            cumulative += gym[i].length * i;
            // If the value is not inside of that bucket, keep going
            if (bucket >= cumulative) continue;
            // Get the address of a random Camel with that alpha score
            return gym[i][seed % gym[i].length].owner;
        }

        return address(0x0);
    }

    function onERC721Received(address, address from, uint256, bytes calldata) external pure override returns (bytes4) {
        require(from == address(0x0), "Cannot send tokens to GOLDverse directly");
        return IERC721Receiver.onERC721Received.selector;
    }
}
