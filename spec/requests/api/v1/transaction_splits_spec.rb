# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transaction Splits', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) { family.accounts.create!(name: 'Checking', balance: 1000, currency: 'USD', accountable: Depository.create!) }
  let(:category) { family.categories.create!(name: 'Household', color: '#4da568', lucide_icon: 'house') }
  let!(:entry) do
    account.entries.create!(
      date: Date.current,
      amount: 31.5,
      name: 'AMZN Mktp US*2K1AB3C0',
      currency: 'USD',
      entryable: Transaction.new(kind: 'standard')
    )
  end
  let(:transaction_id) { entry.entryable_id }

  path '/api/v1/transactions/{transaction_id}/split' do
    parameter name: :transaction_id, in: :path, type: :string, required: true,
              description: 'Transaction ID. For show, update and destroy a split child resolves to its parent.'

    get 'Retrieve the split of a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'split retrieved' do
        schema '$ref' => '#/components/schemas/TransactionSplit'

        before { entry.split!([ { name: 'A', amount: 10 }, { name: 'B', amount: 21.5 } ]) }

        run_test!
      end

      response '404', 'transaction not found or not split' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end

    post 'Split a transaction' do
      tags 'Transactions'
      description 'Splits a posted transaction into children that together add up to it. ' \
                  'Children share the parent\'s date, account, currency and sign, so send positive amounts ' \
                  'that sum to the transaction\'s absolute amount. The parent is kept, marked excluded from ' \
                  'budgets and reports, and protected from provider sync. Pending, transfer, excluded and ' \
                  'already-split transactions cannot be split.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[splits],
        properties: {
          splits: {
            type: :array,
            minItems: 2,
            maxItems: 50,
            description: 'At least two parts whose amounts sum exactly to the transaction amount',
            items: {
              type: :object,
              required: %w[amount],
              properties: {
                name: { type: :string, description: 'Defaults to the transaction name' },
                amount: { type: :string, description: 'Positive decimal, at most the currency\'s minor-unit precision' },
                category_id: { type: :string, format: :uuid },
                notes: { type: :string },
                excluded: { type: :boolean, description: 'Exclude this part from budgets and reports' }
              }
            }
          }
        }
      }

      response '201', 'transaction split' do
        schema '$ref' => '#/components/schemas/TransactionSplit'

        let(:body) { { splits: [ { name: 'Cable', amount: '19.98', category_id: category.id }, { amount: '11.52' } ] } }

        run_test!
      end

      response '422', 'invalid split' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { splits: [ { amount: '10' }, { amount: '10' } ] } }

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:transaction_id) { SecureRandom.uuid }
        let(:body) { { splits: [ { amount: '10' }, { amount: '21.5' } ] } }

        run_test!
      end
    end

    put 'Replace the split of a transaction' do
      tags 'Transactions'
      description 'Replaces an existing split atomically; the request has the same shape as creating one.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[splits],
        properties: {
          splits: {
            type: :array,
            items: {
              type: :object,
              required: %w[amount],
              properties: {
                name: { type: :string },
                amount: { type: :string },
                category_id: { type: :string, format: :uuid },
                notes: { type: :string },
                excluded: { type: :boolean }
              }
            }
          }
        }
      }

      response '200', 'split replaced' do
        schema '$ref' => '#/components/schemas/TransactionSplit'

        before { entry.split!([ { name: 'A', amount: 10 }, { name: 'B', amount: 21.5 } ]) }
        let(:body) { { splits: [ { name: 'X', amount: '1.50' }, { name: 'Y', amount: '30' } ] } }

        run_test!
      end

      response '404', 'transaction not found or not split' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { splits: [ { amount: '10' }, { amount: '21.5' } ] } }

        run_test!
      end

      response '422', 'invalid split' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before { entry.split!([ { name: 'A', amount: 10 }, { name: 'B', amount: 21.5 } ]) }
        let(:body) { { splits: [ { amount: '1' }, { amount: '1' } ] } }

        run_test!
      end
    end

    delete 'Remove the split of a transaction' do
      tags 'Transactions'
      description 'Deletes the children and restores the parent to budgets and reports.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'split removed' do
        schema '$ref' => '#/components/schemas/TransactionSplit'

        before { entry.split!([ { name: 'A', amount: 10 }, { name: 'B', amount: 21.5 } ]) }

        run_test!
      end

      response '404', 'transaction not found or not split' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end
end
