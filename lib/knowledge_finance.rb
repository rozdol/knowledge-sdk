# frozen_string_literal: true

# Finance is trusted package code. Installing its ontology remains explicit.
require_relative "knowledge_finance/model"
require_relative "knowledge_finance/accounting"
require_relative "knowledge_finance/projection"
require_relative "knowledge_finance/datasets"
require_relative "knowledge_finance/reporting"
require_relative "knowledge_finance/planning"
require_relative "knowledge_finance/flex_statement"
require_relative "knowledge_finance/proposals"
require_relative "knowledge_finance/conversation"
require_relative "knowledge_finance/integrations"
require_relative "knowledge_finance/cli"

KnowledgeFinance::Plugin.register
