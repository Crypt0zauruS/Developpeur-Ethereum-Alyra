// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;
// at least 0.8.12 to use string.concat()
// I could have used abi.encodePacked() but I wanted to use this new method
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
/** 
a getter 'owner' is available
a modifier 'onlyOwner' is available
the function 'transferOwnership' is available to transfer the ownership of the contract
*/
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Strings.sol";

contract Voting is Ownable {

  // Variables
  mapping (address => bool) public whitelist;
  mapping (address => Voter) public voters;
  Proposal[] public proposals; 
  WorkflowStatus public status;
  uint winningProposalId;
  uint votersCounter;
  bool public _paused;

  // Structure of a voter
  struct Voter {
    bool isRegistered;
    bool hasVoted;
    uint votedProposalId;
  }

  // Structure of a proposal
  struct Proposal {
    string description;
    uint voteCount;
  }

  /**  
  Enum for the different status of the workflow.
  default value : RegisteringVoters
  */
  enum WorkflowStatus {
    RegisteringVoters,
    ProposalsRegistrationStarted,
    ProposalsRegistrationEnded,
    VotingSessionStarted,
    VotingSessionEnded,
    VotesTallied
  }

  // Events
  event VoterRegistered(address voterAddress); 
  event WorkflowStatusChange(WorkflowStatus previousStatus, WorkflowStatus newStatus);
  event ProposalRegistered(uint proposalId);
  event Voted (address voter, uint proposalId);
  event Paused();
  event unPaused();
  event AddedToWhitelist(address authorized);
  event RemovedFromWhitelist(address unauthorized);

  /**
  @dev The onlyWhenNotPaused modifier checks if the contract is paused before executing the function.
  If the contract is paused, it will stop the function with an error message "Contract is paused".
  This modifier can be used to ensure that critical functions can only be executed when the contract is not paused.
  Even onlyOwner Workflow functions can be paused: as a human, owner can forget that the contract was paused.
  */
  modifier onlyWhenNotPaused {
    require(!_paused, "Contract is paused");
    _;
  }

  /**
  @dev Modifier to check if the provided address is not equal to address(0).
  @param _addr The address to be validated.
  @notice If the address is equal to address(0), the function will be stopped with the message "Address must be valid".
  */
  modifier validAddress(address _addr) {
    require(_addr != address(0), "Address must be valid");
    _;
  }

  /**
  @dev Modifier to check if msg.sender is whitelisted and registered.
  If it's not the case, the function will be stopped with the message "You must be whitelisted and registered".
  */
  modifier whitelistedAndRegisteredSender() {
    require(whitelist[msg.sender] && voters[msg.sender].isRegistered, "You must be whitelisted and registered");
    _;
  }

  /**
  @dev Sets the paused status of the contract
  @param val The new paused status, either true or false
  @notice Only the contract owner is able to execute this function.
  This function can be used to pause the contract at any time in case of an emergency or a problem
  */
  function setPaused(bool val) external onlyOwner {
    require(_paused != val, "Contract already in this state");
    _paused = val;
    if(_paused) {
      emit Paused();
    } else {
      emit unPaused();
    }
  }

  /**
  @dev Adds a new address to the whitelist if it is not already in the list only during the voter registration phase.
  This function can only be executed by the owner of the contract and the
  address provided must be a valid address.
  @param _authorized The address to be added to the whitelist.
  */
  function addToWhitelist(address _authorized) external onlyOwner validAddress(_authorized) {
    require(!whitelist[_authorized], "Address already in whitelist");
    require(status==WorkflowStatus.RegisteringVoters, "Voters registration is over");
    whitelist[_authorized] = true;
    emit AddedToWhitelist(_authorized);
  }

  /**
  @dev Function to remove an address from the whitelist only during the voter registration phase.
  @notice The address must be a valid address and the caller must be the contract owner.
  The address will also be marked as false in the isRegistered Voter struct from voters mapping.
  The purpose of this function is to allow the owner to remove an address from the whitelist if the person
  is no longer a member of the organisation during the Registration process, or if the address was added by mistake by the owner.
  @param _unauthorized the address to be removed
  */
  function removeFromWhitelist(address _unauthorized) external onlyOwner validAddress(_unauthorized) {
    require(status==WorkflowStatus.RegisteringVoters, "Voters registration is over");
    require(whitelist[_unauthorized], "Address not whitelisted");
    whitelist[_unauthorized] = false;
    voters[_unauthorized].isRegistered = false;
    if (votersCounter > 0) {
        votersCounter--;
    }
    emit RemovedFromWhitelist(_unauthorized);
  }

  /**
  @dev Registers a voter by checking if the voter registration is open, the voter is whitelisted, and the voter is 
  not already registered.
  @notice Emits VoterRegistered event with the address of the registered voter
  */
  function registerVoter() external onlyWhenNotPaused {
    require(status == WorkflowStatus.RegisteringVoters, "Voter registration not opened");
    require(whitelist[msg.sender], "Voter must be whitelisted");
    require(!voters[msg.sender].isRegistered, "Voter already registered");
    voters[msg.sender].isRegistered = true;
    votersCounter++;
    emit VoterRegistered(msg.sender);
  }

  /**
  @dev Starts the proposal registration process. This function can only be called by the contract owner.
  @notice Check if the voter registration is not completed or if proposals have already been registered.
  Check if the whitelist is not empty and if there is at least one registered voter.
  Return Changes the status to ProposalsRegistrationStarted and emits a WorkflowStatusChange event.
  */
  function startProposalRegistration() external onlyOwner onlyWhenNotPaused {
    require(status == WorkflowStatus.RegisteringVoters, "Voter registration must be completed before proposal registration");
    require(proposals.length == 0, "Proposals registration already started");
    require(votersCounter > 0, "No registered voters");
    status = WorkflowStatus.ProposalsRegistrationStarted;
    emit WorkflowStatusChange(WorkflowStatus.RegisteringVoters, status);
  }

  /**
  @dev Registers a proposal with a given description.
  @notice Only allowed when the workflow status is "Proposal Registration Started" and the sender must be a whitelisted AND registered voter
  The proposal description must be valid (not empty).
  If successful, a new proposal is added to the proposals array and a ProposalRegistered event is emitted with the proposal ID.
  This function is pauseable in case of abuse, as "each member of the organisation can register as many proposals as he wants".
  So, in case of huge number of proposals, a pause allows to recall good behaviour.
  @param _proposalDescription the string proposal description
  */
  function registerProposal(string calldata _proposalDescription) external onlyWhenNotPaused whitelistedAndRegisteredSender {
    require(status == WorkflowStatus.ProposalsRegistrationStarted, "Proposal registration is not opened");
    require(bytes(_proposalDescription).length > 0, "Proposal description must be valid");
    proposals.push(Proposal({
      description: _proposalDescription,
      voteCount: 0
    }));
    uint proposalId = proposals.length - 1;
    emit ProposalRegistered(proposalId);
  }

  /**
  * @dev Returns an array of strings, each string is a proposal description with its Id
  * @notice This facillitates the user experience to view all the proposalsin one time, as there is no frontend for this project
  */
  function displayProposals() external view returns (string[] memory) {
    require(proposals.length > 0, "No proposals have been registered yet");
    string[] memory proposalsDescription = new string[](proposals.length);
    for (uint i = 0; i < proposals.length; i++) {
      proposalsDescription[i] = string.concat("Id ", Strings.toString(i),  " : ", proposals[i].description);
    }
    return proposalsDescription;
  }

  /**
  @dev Function to end the proposal registration process
  Only the contract owner can call this function.
  @notice
  It requires that the current status is ProposalsRegistrationStarted and that at least one proposal has been registered.
  If the requirement is not met, an error message "Proposal registration is not open." is thrown.
  If the requirement is met, the status is set to ProposalsRegistrationEnded and a WorkflowStatusChange event is 
  emitted with the previous and new status.
  */
  function endProposalRegistration() external onlyOwner onlyWhenNotPaused {
    require(status == WorkflowStatus.ProposalsRegistrationStarted, "Proposal registration is not opened");
    // if no proposal made
    if(proposals.length == 0) {
        proposals.push(Proposal({
          description: "Voters made NO PROPOSAL",
          voteCount: 0
        }));
    }
    status = WorkflowStatus.ProposalsRegistrationEnded;
    emit WorkflowStatusChange(WorkflowStatus.ProposalsRegistrationStarted, status);
  }

  /**
  @dev Starts the voting session if the proposal registration has ended.
  @notice Proposal registration must be completed before starting the voting session.
  Emits WorkflowStatusChange if voting session is successfully started.
  */
  function startVotingSession() external onlyOwner onlyWhenNotPaused {
    require(status == WorkflowStatus.ProposalsRegistrationEnded, "Proposal registration must be ended before voting session");
    status = WorkflowStatus.VotingSessionStarted;
    emit WorkflowStatusChange(WorkflowStatus.ProposalsRegistrationEnded, status);
  }

  /**
  @dev Allows a registered voter to vote for a specific proposal during an open voting session.
  Emits Voted when a voter successfully casts their vote.
  @param _proposalId the id of the proposal to vote for.
  @notice No Pauseable because it's a voting session
  */
  function vote(uint _proposalId) external whitelistedAndRegisteredSender {
    require(status == WorkflowStatus.VotingSessionStarted, "Voting session is not opened");
    require(!voters[msg.sender].hasVoted, "Voter has already voted");
    require(_proposalId >= 0 && _proposalId < proposals.length, "Proposal Id is not valid");
    voters[msg.sender].hasVoted = true;
    voters[msg.sender].votedProposalId = _proposalId;
    proposals[_proposalId].voteCount++;
    emit Voted(msg.sender, _proposalId);
  }

  /**
  @dev This function allows the owner to end a voting session. The function first checks that the current status is 
  set to VotingSessionStarted, and if it is, it updates the status to VotingSessionEnded and emits a WorkflowStatusChange 
  event. Lastly, it calls the tallyVotes function to process the results of the voting session.
  @notice The voting session must be opened (status must be VotingSessionStarted).
  Emit The function emits a WorkflowStatusChange event, indicating the change in status from VotingSessionStarted to 
  VotingSessionEnded.
  */
  function endVotingSession() external onlyOwner onlyWhenNotPaused {
    require(status == WorkflowStatus.VotingSessionStarted, "Voting session is not opened");
    status = WorkflowStatus.VotingSessionEnded;
    emit WorkflowStatusChange(WorkflowStatus.VotingSessionStarted, status);
    _tallyVotes();
  }

  /**
  @dev Tally the votes for each proposal and find the winning proposal by
  comparing the vote count of each proposal. After the vote count has been tallied,
  the status of the workflow is updated to reflect that the votes have
  been tallied.
  */
  function _tallyVotes() private {
    for (uint i = 0; i < proposals.length; i++) {
      if (proposals[i].voteCount > proposals[winningProposalId].voteCount) {
        winningProposalId = i;
      }
    }
    status = WorkflowStatus.VotesTallied;
    emit WorkflowStatusChange(WorkflowStatus.VotingSessionEnded, status);
  }

  /**
  @dev Returns the winning proposal id and its vote count.
  @notice If there is a tie, the lowest id wins. If there is no vote, the first proposal wins. This is incentive to vote.
  Return The winning proposal id, its vote count and the description
  Throws If votes are not yet tallied.
  */
  function getWinner() external view returns (uint, uint, string memory) {
    require(status == WorkflowStatus.VotesTallied, "Votes must be tallied before getting the winner");
    uint voteCount = proposals[winningProposalId].voteCount;
    if (voteCount == 0) {
      // no vote was cast, return the first proposal
      return (0, 0, string.concat(proposals[0].description, ", wins as NO VOTE was cast"));
    }
    // check if there is a tie in the vote count
    for (uint i = 0; i < proposals.length; i++) {
      if (i != winningProposalId && proposals[i].voteCount == voteCount) {
        // if there is a tie
        return (winningProposalId, voteCount, string.concat(proposals[winningProposalId].description, " - ", Strings.toString(voteCount), " vote(s).",
        " TIE(s) ! Lowest Id wins. Nearest tie Id is ", Strings.toString(i)
        ));
      }
    }
    return (winningProposalId, voteCount, string.concat(proposals[winningProposalId].description, " - ", Strings.toString(voteCount), " vote(s)"));
  }
  
  /**
  @dev Reverts the renouncing of ownership by overriding the renounceOwnership function from the Ownable contract.
  @notice I don't think it's a good idea for a trusting voting contract to be able to relinquish ownership.
  It would make impossible to terminate the vote and oblige to deploy a new contract to start a new session of voting at will.
  I still left the possibility of transferring ownership of the contract to another address.
  */
  function renounceOwnership() public view override onlyOwner {
    revert("Cannot renounce ownership");
  }

}

/**
TODO, but out of the scope of this project:
- Limit the number of proposals by voters to 5 to prevent too many proposals.
- Add this Constructor to start the contract in a paused state, and allow the owner to add addresses to the whitelist first.

  constructor() {
    _paused = true;
    emit Paused();
  }

- Or import the existing whitelist of the members of the organisation

THOUGHTS
- I've thought about the idea to reset the contract to start a new session of voting. But finally I think it's better to 
 use 1 contract per session of voting: "contract must inspire trust". So I choose to make a voting contract easily readable,
 at any time, "as is", making changes impossible after votes tallied.
 Make the contract reusable implies to use an array for the whitelist, which is more expensive in gas than a mapping.
 - Same thing for the idea of giving the ability for the owner to change manually the status of the workflow... Very bad for trust i think.
 */