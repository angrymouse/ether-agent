// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

library Math {
        function min(uint256 a, uint256 b) internal pure returns (uint256) {
            return a < b ? a : b;
        }
}
contract AgentContract {
    struct UnbondingRecord {
        uint256 amount;
        uint256 startedUnbondingAt;
    }

    struct Proposal {
        address submitter;
        uint32[] submittedTokens;
        uint256 blockHeight;
        bool active;
    }

    struct Challenge {
        uint256 targetProposalId;
        uint256 votesYes;
        bool resolved;
        mapping(address => bool) voters;
    }

    mapping(address => uint256) public bondedBalances;
    
    mapping(address => UnbondingRecord[]) public unbondingRecords;
    
    Proposal[] public proposedTokens;
    Challenge[] public challenges;
    
    uint256 public immutable unbondingPeriod;
    uint256 public immutable submissionThreshold;
    uint256 public dignityTamperingAmount;
    uint256 public immutable fine;
    uint256 public totalBonded;

    event Bonded(address indexed account, uint256 amount);
    event UnbondingStarted(address indexed account, uint256 amount, uint256 index);
    event UnbondingCompleted(address indexed account, uint256 amount);
    event ProposalSubmitted(uint256 indexed proposalId, address indexed submitter);
    event ChallengeCreated(uint256 indexed challengeId, uint256 indexed proposalId);
    event VoteCast(uint256 indexed challengeId, address indexed voter, uint256 weight);

    constructor(uint256 _unbondingPeriod, uint256 _submissionThreshold, uint256 _fine) {
        unbondingPeriod = _unbondingPeriod;
        submissionThreshold = _submissionThreshold;
        fine = _fine;
    }

    receive() external payable {
        bond();
    }

    function bond() public payable {
        bondedBalances[msg.sender] += msg.value;
        totalBonded += msg.value;
        emit Bonded(msg.sender, msg.value);
    }

    function startUnbonding(uint256 amount) external {
        require(bondedBalances[msg.sender] >= amount, "Insufficient bonded balance");
        
        bondedBalances[msg.sender] -= amount;
        totalBonded -= amount;
        
        unbondingRecords[msg.sender].push(UnbondingRecord({
            amount: amount,
            startedUnbondingAt: block.number
        }));
        
        emit UnbondingStarted(msg.sender, amount, unbondingRecords[msg.sender].length - 1);
    }

    function finishUnbonding(uint256 recordIndex) external {
        UnbondingRecord storage record = unbondingRecords[msg.sender][recordIndex];
        require(block.number >= record.startedUnbondingAt + unbondingPeriod, "Unbonding period not completed");
        
        uint256 amount = record.amount;
        delete unbondingRecords[msg.sender][recordIndex];
        
        payable(msg.sender).transfer(amount);
        emit UnbondingCompleted(msg.sender, amount);
    }

    function propose(uint32[] calldata tokens) external {
        require(bondedBalances[msg.sender] >= submissionThreshold, "Insufficient governance power");
        
        proposedTokens.push(Proposal({
            submitter: msg.sender,
            submittedTokens: tokens,
            blockHeight: block.number,
            active: true
        }));
        
        emit ProposalSubmitted(proposedTokens.length - 1, msg.sender);
    }

    function challengeProposal(uint256 proposalId) external {
        require(proposalId < proposedTokens.length, "Invalid proposal");
        Proposal storage proposal = proposedTokens[proposalId];
        require(proposal.active, "Proposal not active");
        require(proposal.blockHeight > block.number, "Challenge period expired");

        for (uint256 i = 0; i < challenges.length; i++) {
            if (challenges[i].targetProposalId == proposalId && !challenges[i].resolved) {
                revert("Existing active challenge");
            }
        }

        challenges.push();
        Challenge storage newChallenge = challenges[challenges.length - 1];
        newChallenge.targetProposalId = proposalId;
        newChallenge.votesYes = 0;
        newChallenge.resolved = false;
        
        emit ChallengeCreated(challenges.length - 1, proposalId);
    }

    function voteOnChallenge(uint256 challengeId) external {
        require(challengeId < challenges.length, "Invalid challenge");
        Challenge storage challenge = challenges[challengeId];
        require(!challenge.resolved, "Challenge resolved");
        require(!challenge.voters[msg.sender], "Already voted");

        uint256 votingPower = bondedBalances[msg.sender];
        require(votingPower > 0, "No voting power");

        challenge.votesYes += votingPower;
        challenge.voters[msg.sender] = true;
        emit VoteCast(challengeId, msg.sender, votingPower);

        if (challenge.votesYes * 100 >= totalBonded * 51) {
            _resolveSuccessfulChallenge(challengeId);
        }
    }

    function _resolveSuccessfulChallenge(uint256 challengeId) private {
        Challenge storage challenge = challenges[challengeId];
        challenge.resolved = true;
        
        Proposal storage proposal = proposedTokens[challenge.targetProposalId];
        proposal.active = false;

        uint256 remainingFine = fine;
        
        uint256 bonded = bondedBalances[proposal.submitter];
        if (bonded >= remainingFine) {
            bondedBalances[proposal.submitter] -= remainingFine;
            totalBonded -= remainingFine;
            remainingFine = 0;
        } else {
            remainingFine -= bonded;
            bondedBalances[proposal.submitter] = 0;
            totalBonded -= bonded;
        }

        UnbondingRecord[] storage records = unbondingRecords[proposal.submitter];
        for (uint256 i = 0; i < records.length && remainingFine > 0; i++) {
            uint256 deduct = Math.min(records[i].amount, remainingFine);
            records[i].amount -= deduct;
            remainingFine -= deduct;
            
            if (records[i].amount == 0) {
                delete records[i];
            }
        }
        dignityTamperingAmount+=1;
    }
    function getSubmittedTokens(uint256 proposalId) external view returns (uint32[] memory) {
      require(proposalId < proposedTokens.length, "Invalid proposalId");
      return proposedTokens[proposalId].submittedTokens;
    }


}