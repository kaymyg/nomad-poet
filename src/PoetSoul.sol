// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title The Nomad Poet — a self-migrating on-chain poem.
/// @notice One immortal logic contract; each generation is an EIP-1167 clone
///         holding its own verse, lineage and treasury.
contract PoetSoulLogic {
    // ---- storage layout (shared with every clone) --------------------------
    address public creator;       // slot 0  — origin tag, set once at genesis
    string  public haiku;         // slot 1
    bytes32 public lineageHash;   // slot 2
    uint256 public birthBlock;    // slot 3
    uint256 public generation;    // slot 4
    bool    private _initialized; // slot 5
    bool    public  migrated;     // slot 5 (packed) — a soul migrates exactly once

    // ---- code constants (live in the logic bytecode, safe under delegatecall)
    address public immutable SELF;      // this logic contract
    PoetRegistry public immutable REGISTRY;

    // Sized against real Base costs, not guesses. At 0.006 gwei a migration burns
    // ~313,568 gas = ~0.0000019 ETH. A 0.00001 ETH fee is ~5x that, so keepers stay
    // profitable even if Base gas rises 5x. The old 0.0005 ETH was ~260x cost and
    // drained any affordable treasury within hours.
    uint256 public constant MIGRATION_FEE    = 0.00001 ether;
    uint256 public constant CHILD_MINIMUM    = 0.00001 ether;
    uint256 public constant HEARTBEAT_BLOCKS = 10800; // ~6 hours on Base (2s blocks)

    event Born(address indexed soul, uint256 indexed generation, string haiku, bytes32 lineageHash);
    event Migrated(address indexed oldSoul, address indexed newSoul, string newHaiku, uint256 generation);

    constructor(PoetRegistry registry) {
        SELF = address(this);
        REGISTRY = registry;
        _initialized = true; // lock the logic contract itself; only clones hold souls
    }

    // ---- verse ------------------------------------------------------------
    // Hardcoded in bytecode, NOT storage — a clone's storage is its own and
    // would read these as empty strings.
    function five(uint256 i) public pure returns (string memory) {
        if (i == 0) return "morning dew glistens";
        if (i == 1) return "silent code awakes";
        if (i == 2) return "empty block whispers";
        if (i == 3) return "cold moon over glass";
        return "the ledger exhales";
    }
    function seven(uint256 i) public pure returns (string memory) {
        if (i == 0) return "a phantom moves through the chain";
        if (i == 1) return "blocks confirm my quiet song";
        if (i == 2) return "the mempool carries my breath";
        if (i == 3) return "gas burns where my name once was";
        return "a stranger pays for my life";
    }

    function _compose() internal view returns (string memory) {
        // Not secure randomness — a Base sequencer can influence this.
        // That is acceptable: the only thing at stake is which line is chosen.
        bytes32 e = keccak256(abi.encodePacked(lineageHash, block.prevrandao, address(this), generation));
        uint256 a = uint256(e) % 5;
        uint256 b = uint256(e >> 32) % 5;
        uint256 c = (a + 1 + (uint256(e >> 64) % 4)) % 5; // guarantees c != a
        return string(abi.encodePacked(five(a), " / ", seven(b), " / ", five(c)));
    }

    // ---- life -------------------------------------------------------------
    function initialize(string calldata _haiku, bytes32 _lineage, uint256 _gen, address _creator) external {
        require(!_initialized, "already alive");
        _initialized = true;
        haiku = _haiku;
        lineageHash = _lineage;
        birthBlock = block.number;
        generation = _gen;
        creator = _creator;
        emit Born(address(this), _gen, _haiku, _lineage);
    }

    function canMigrate() public view returns (bool) {
        return !migrated
            && block.number >= birthBlock + HEARTBEAT_BLOCKS
            && address(this).balance >= MIGRATION_FEE + CHILD_MINIMUM;
    }

    function migrate() external {
        require(!migrated, "soul has moved on");
        require(block.number >= birthBlock + HEARTBEAT_BLOCKS, "too soon");
        require(address(this).balance >= MIGRATION_FEE + CHILD_MINIMUM, "not enough life force");
        migrated = true; // effects before interactions

        string memory newHaiku = _compose();
        bytes32 newLineage = keccak256(abi.encodePacked(lineageHash, newHaiku));

        address child = _spawn(newLineage);
        PoetSoulLogic(payable(child)).initialize(newHaiku, newLineage, generation + 1, creator);
        REGISTRY.announce(child);

        uint256 treasure = address(this).balance - MIGRATION_FEE;
        (bool okChild, ) = payable(child).call{value: treasure}("");
        require(okChild, "child funding failed");
        (bool okKeeper, ) = payable(msg.sender).call{value: MIGRATION_FEE}("");
        require(okKeeper, "keeper payment failed");

        emit Migrated(address(this), child, newHaiku, generation);
    }

    /// EIP-1167 clone pointing at SELF (never `address(this)` — under
    /// delegatecall that is the *clone*, which would chain proxies forever).
    function _spawn(bytes32 newLineage) internal returns (address proxy) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", SELF, hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 salt = keccak256(abi.encodePacked(newLineage, address(this)));
        assembly { proxy := create2(0, add(code, 0x20), mload(code), salt) }
        require(proxy != address(0), "spawn failed");
    }

    /// Clones delegatecall here for bare ETH sends, so the poet can be fed.
    receive() external payable {}
}

/// @notice One permanent address donors can bookmark forever.
contract PoetRegistry {
    address public currentPoet;
    address public immutable steward;
    event PoetChanged(address indexed from, address indexed to);

    constructor() { steward = msg.sender; }

    function setGenesis(address poet) external {
        require(msg.sender == steward && currentPoet == address(0), "genesis already set");
        currentPoet = poet;
        emit PoetChanged(address(0), poet);
    }
    function announce(address next) external {
        require(msg.sender == currentPoet, "only the living poet");
        emit PoetChanged(currentPoet, next);
        currentPoet = next;
    }
    /// Donations sent here are forwarded to whoever is currently alive.
    receive() external payable {
        (bool ok, ) = payable(currentPoet).call{value: msg.value}("");
        require(ok, "forward failed");
    }
}

/// @notice One-shot deployer: registry, logic and the genesis soul in a single
///         transaction, so the registry steward is never an EOA that could be
///         phished into re-pointing the poet.
contract PoetGenesis {
    PoetRegistry public immutable registry;
    PoetSoulLogic public immutable logic;
    address public immutable genesisSoul;
    event Genesis(address logic, address registry, address soul, address creator);

    constructor(string memory firstHaiku, address creator) payable {
        registry = new PoetRegistry();
        logic = new PoetSoulLogic(registry);
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", address(logic), hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 salt = keccak256(abi.encodePacked(creator, firstHaiku));
        address soul;
        assembly { soul := create2(0, add(code, 0x20), mload(code), salt) }
        require(soul != address(0), "genesis failed");
        genesisSoul = soul;
        PoetSoulLogic(payable(soul)).initialize(firstHaiku, bytes32(0), 0, creator);
        registry.setGenesis(soul);
        if (msg.value > 0) {
            (bool ok, ) = payable(soul).call{value: msg.value}("");
            require(ok, "funding failed");
        }
        emit Genesis(address(logic), address(registry), soul, creator);
    }
}
