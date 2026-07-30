# frozen_string_literal: true

module KnowledgePlanning
  class Error < StandardError; end
  class InvalidGoal < Error; end
  class GoalNotFound < Error; end
  class InvalidConstraint < Error; end
  class InvalidPlan < Error; end
  class NoCandidates < Error; end
  class NoFeasiblePlan < Error; end
  class ProposalFailure < Error; end
end
