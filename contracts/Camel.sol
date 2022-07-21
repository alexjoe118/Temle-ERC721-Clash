// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

/* --- IMPORTS --- */
import "./GOLD.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";
import "@openzeppelin/contracts/interfaces/IERC721Metadata.sol";
/* --- Contracts --- */

/** 
 * – Interfaces –
 * IMemeverse: the playing field
 * ITraits: the traits that each NFT comprises
 * ICamel: game utility of each Camel + CamelBandit struct
 */
interface IMemeverse {
    function addManyToMemeverseAndGym(address account, uint16[] calldata tokenIds) external;

    function randomBanditOwner(uint256 seed) external view returns (address);
}

interface ITraits {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface ICamel {
    // Struct that stores each Camel's traits
    struct CamelBandit {
        bool isCamel;
        uint8 hat;
        uint8 eyes;
        uint8 feet;
        uint8 fur;
        uint8 prop;
        uint8 alphaIndex;
    }

    function getPaidTokens() external view returns (uint256);

    function getTokenTraits(uint256 tokenId)
        external
        view
        returns (CamelBandit memory);
}

contract Camel is ICamel, ERC721Enumerable, Ownable, Pausable {
    using SafeERC20 for IERC20;

    /* Mint variables and constants */
    uint256 public constant MAX_PER_MINT = 5;
    uint256 public constant MINT_PRICE = 0.02 ether; // Mint price
    uint256 public immutable MAX_TOKENS;                 // Max # of tokens that can be minted
    uint256 public PAID_TOKENS;                          // # of tokens that can be claimed for free: MAX_TOKENS/5
    uint16 public minted;                                // # of tokens that have been minted so far

    mapping(uint256 => CamelBandit) private tokenTraits;       // Mapping from tokenId to a struct containing the token's traits
    mapping(uint256 => uint256) private existingCombinations; // Mapping from hashed(tokenTrait) to tokenId to ensure no duplicates

    
    // 0 - 9 are associated with Bandits, 10 - 18 are associated with Virgins
    uint8[][18] public rarities; // List of probabilities for each trait type
    uint8[][18] public aliases;  // List of aliases for Walker's Alias algorithm

    IMemeverse public memeverse; // Reference to the Memeverse for choosing random Bandit thieves
    GOLD public gold;            // Reference to $GOLD for burning
    ITraits public traits;     

    uint256 public reserveLimit = 500;

    /**
     * Instantiate Camel contract and rarity registries
     */
    constructor(address _gold, address _traits, uint256 _maxTokens) ERC721("DesertClash Game", "DesertClash") {
        gold = GOLD(_gold);
        traits = ITraits(_traits);

        MAX_TOKENS = _maxTokens + MAX_PER_MINT;
        PAID_TOKENS = _maxTokens / 5;

        // Walker's Alias Algorithm
        // Bandit
        // hats
        rarities[0] = [190,215,240,100,110,135,160,185,80,210,235,240,80,80,100];
        aliases[0] = [1,2,4,0,5,6,7,9,0,10,11,10,0,0,0];
        // eyes
        rarities[1] = [15,50,200,250,255,150,100];
        aliases[1] = [4,4,4,4,4,4,4];
        // feet
        rarities[2] = [221,100,181,140,224,147,84,228,140];
        aliases[2] = [1,2,5,0,1,7,1,7,5];
        // fur
        rarities[3] = [175,100,40,250,255];
        aliases[3] = [3,0,1,1,4];
        // prop
        rarities[4] = [80,225,227,228,112,240,64,160];
        aliases[4] = [1,2,3,5,6,5,5,4];
        // alphaIndex
        rarities[5] = [8,160,73,255];
        aliases[5] = [2,3,3,3];

        // Camel
        // hats
        rarities[6] = [190,215,240,100,110,135,160,185,80,210,235,240,80,80,100,100,100,245,250,255,90,70];
        aliases[6] = [1,2,4,0,5,6,7,9,0,10,11,17,0,0,0,0,4,18,19,19,20,21];
        // eyes
        rarities[7] = [190,215,240,100,110,135,160];
        aliases[7] = [1,2,4,0,5,6,3];
        // feet
        rarities[8] = [221,100,181,140,224,147,84,228,140,224,250,160,241,207,173,84,254,220,196,140,168,252,140,183,236,252,224,255];
        aliases[8] = [1,2,5,0,1,7,1,10,5,10,11,12,13,14,16,11,17,23,13,14,17,23,23,24,27,27,27,27];
        // fur
        rarities[9] = [175,100,40,250,115,100,185,175,180];
        aliases[9] = [3,0,4,6,6,7,8,8,7];
        // prop
        rarities[10] = [80,225,227,228,112,240,64,160,167,217,171,64,240];
        aliases[10] = [1,2,3,8,2,8,8,9,9,10,12,10,12];
        // alphaIndex
        rarities[11] = [255];
        aliases[11] = [0];
    }

    /** EXTERNAL */

    // Current batch is not revealed until the next batch, there is no way to game this setup.
    // This also implies that at least the last 10 NFTs should be minted by admin, to
    // reveal the previous batch.

    /**
     * Minting function - 90% Camel, 10% Bandit
     * The first 20% are free to claim, the remaining cost $GOLD
     * Due to buffer considerations, staking is not possible immediately:
     * Minter has to wait for 10 mints
     */
    function mint(uint256 amount) external payable whenNotPaused {
        require(tx.origin == _msgSender(), "Only EOA");
        require(
            minted + amount <= MAX_TOKENS - MAX_PER_MINT, // Subtract MAX_PER_MINT, since last MAX_PER_MINT are mintable by admin
            "All tokens minted!"
        );
        require(amount > 0 && amount <= MAX_PER_MINT, "Invalid mint amount!");
        if (minted < PAID_TOKENS) {
            require(
                minted + amount <= PAID_TOKENS,
                "All tokens on sale have already been sold!"
            );
            require(amount * MINT_PRICE == msg.value, "Invalid payment amount!");
        } else {
            require(msg.value == 0);
        }
        uint256 totalGoldCost = 0;
        uint256 seed;
        for (uint256 i = 0; i < amount; i++) {
            minted++;
            seed = random(minted);
            generate(minted, seed);
            address recipient = selectRecipient(seed);
            totalGoldCost += mintCost(minted);
            _safeMint(recipient, minted);
        }
        if (totalGoldCost > 0) gold.burn(_msgSender(), totalGoldCost);
    }

    /**
     * the first 20% are paid in ETH
     * the next 20% are 20000 $GOLD
     * the next 40% are 40000 $GOLD
     * the final 20% are 80000 $GOLD
     * @param tokenId: the ID to check the cost of to mint
     * @return the cost of the given token ID
     */
    function mintCost(uint256 tokenId) public view returns (uint256) {
        if (tokenId <= PAID_TOKENS) return 0;
        if (tokenId <= (MAX_TOKENS * 2) / 5) return 20000 ether;
        if (tokenId <= (MAX_TOKENS * 4) / 5) return 40000 ether;
        return 80000 ether;
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual override {
      // Hardcode the Memeverse's approval so that users don't waste gas waiting for approval
      if (_msgSender() != address(memeverse)) {
          require(
              _isApprovedOrOwner(_msgSender(), tokenId),
              "ERC721: transfer caller is not owner nor approved"
          );
      }
      _transfer(from, to, tokenId);
    }

    /** INTERNAL */

    /**
     * generates traits for a specific token, check to ensure uniqueness
     * @param tokenId: the id of the token to generate traits for
     * @param seed: a pseudorandom 256 bit number to derive traits from
     * returns t: a struct of traits for the given token ID
     */
    function generate(uint256 tokenId, uint256 seed) internal returns (CamelBandit memory t) {
      t = selectTraits(seed);
      if (existingCombinations[structToHash(t)] == 0) {
          tokenTraits[tokenId] = t;
          existingCombinations[structToHash(t)] = tokenId;
          return t;
      }
      return generate(tokenId, random(seed));
    }

    /**
     * uses A.J. Walker's Alias algorithm for O(1) rarity table lookup
     * ensuring O(1) instead of O(n) reduces mint cost by more than 50%
     * probability & alias tables are generated off-chain beforehand
     * @param seed: portion of the 256 bit seed to remove trait correlation
     * @param traitType: the trait being selected
     * returns the ID of the randomly selected trait
     */
    function selectTrait(uint16 seed, uint8 traitType) internal view returns (uint8) {
      uint8 trait = uint8(seed) % uint8(rarities[traitType].length);
      if (seed >> 8 < rarities[traitType][trait]) return trait;
      return aliases[traitType][trait];
    }

    /**
     * the first 20% (ETH purchases) go to the minter
     * the remaining 80% have a 10% chance to be given to a random staked Bandit
     * @param seed: a random value to select a recipient from
     * @return the address of the recipient (either the minter or the Bandit thief's owner)
     */
    function selectRecipient(uint256 seed) internal view returns (address) {
      if (minted <= PAID_TOKENS || ((seed >> 245) % 10) != 0)
          return _msgSender(); // top 10 bits haven't been used
      // 144 bits reserved for trait selection
      address thief = memeverse.randomBanditOwner(seed >> 144);
      if (thief == address(0x0)) return _msgSender();
      return thief;
    }

    /**
     * selects the species and all of its traits based on the seed value
     * @param seed: a pseudorandom 256 bit number to derive traits from
     * returns t:  a struct of randomly selected traits
     */
    function selectTraits(uint256 seed)internal view returns (CamelBandit memory t){
        t.isCamel = (seed & 0xFFFF) % 10 != 0;
        uint8 shift = t.isCamel ? 0 : 6;
        seed >>= 16;
        t.hat = selectTrait(uint16(seed & 0xFFFF), 0 + shift);
        seed >>= 16;
        t.eyes = selectTrait(uint16(seed & 0xFFFF), 1 + shift);
        seed >>= 16;
        t.feet = selectTrait(uint16(seed & 0xFFFF), 2 + shift);
        seed >>= 16;
        t.fur = selectTrait(uint16(seed & 0xFFFF), 3 + shift);
        seed >>= 16;
        t.prop = selectTrait(uint16(seed & 0xFFFF), 4 + shift);
        seed >>= 16;
        t.alphaIndex = selectTrait(uint16(seed & 0xFFFF), 5 + shift);
    }

    /**
     * Converts a struct to a 256 bit hash to check for uniqueness
     * @param s the struct to pack into a hash
     * @return the 256 bit hash of the struct
     */
    function structToHash(CamelBandit memory s) internal pure returns (uint256) {
        return
            uint256(
                sha256(
                    abi.encodePacked(
                        s.isCamel,
                        s.hat,
                        s.eyes,
                        s.feet,
                        s.fur,
                        s.prop,
                        s.alphaIndex
                    )
                )
            );
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

    /** READ */

    /** Only used in traits in a couple of places that all boil down to tokenURI
     * so it is safe to buffer the reveal
     */
    function getTokenTraits(uint256 tokenId) external view override returns (CamelBandit memory) {
        // To prevent people from minting only Bandits,
        // reveal the minted batch if the next batch has been minted
        require(totalSupply() >= tokenId + MAX_PER_MINT);
        return tokenTraits[tokenId];
    }

    function getPaidTokens() external view override returns (uint256) {
        return PAID_TOKENS;
    }

    /** ADMIN */

    /**
     * Called after deployment so that the contract can get random Bandit thieves
     * @param _memeverse the address of the Memeverse
     */
    function setMemeverse(address _memeverse) external onlyOwner {
        memeverse = IMemeverse(_memeverse);
    }

    /**
     * allows owner to withdraw funds from minting
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * Reserve amounts for treasury/marketing
     */
    function reserve(uint256 amount) external whenNotPaused onlyOwner {
        require(
            minted + amount <= MAX_TOKENS - MAX_PER_MINT,
            "All tokens minted!"
        );
        require(amount > 0 && amount <= MAX_PER_MINT, "Invalid mint amount!");
        require(reserveLimit > 0);
        uint256 seed;
        for (uint256 i = 0; i < amount; i++) {
            minted++;
            seed = random(minted);
            generate(minted, seed);
            _safeMint(owner(), minted);
        }
        reserveLimit -= amount;
    }

    /**
     * Reveals the last batch for admin to mint
     */
    function adminMintLastBatch() external {
        require(minted == MAX_TOKENS - MAX_PER_MINT);
        require(owner() == msg.sender);
        _safeMint(owner(), MAX_PER_MINT);
    }

    /**
     * Updates the number of tokens for sale
     */
    function setPaidTokens(uint256 _paidTokens) external onlyOwner {
        PAID_TOKENS = _paidTokens;
    }

    /**
     * Toggle minting on/off
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

    /** RENDER */

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        // to prevent people from minting only Bandits. We reveal the minted batch 
        // if the next batch has been minted.
        require(totalSupply() >= tokenId + MAX_PER_MINT);
        return traits.tokenURI(tokenId);
    }
}

