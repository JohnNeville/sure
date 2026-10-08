# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Security Prices', type: :request do
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
      password_confirmation: 'password123',
      role: 'admin'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      display_key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    # Persist an invalid key shape intentionally so rswag can document 403.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      display_key: key,
      scopes: [],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      name: 'Investment Account',
      balance: 50_000,
      currency: 'USD',
      accountable: Investment.create!
    )
  end

  let!(:security) do
    Security.create!(
      ticker: 'VTI',
      name: 'Vanguard Total Stock Market ETF',
      country_code: 'US',
      exchange_operating_mic: 'ARCX'
    )
  end

  let!(:holding) do
    Holding.create!(
      account: account,
      security: security,
      date: Date.current,
      qty: 100,
      price: 250.50,
      amount: 25_050,
      currency: 'USD'
    )
  end

  let!(:security_price) do
    Security::Price.create!(
      security: security,
      date: Date.current,
      price: 250.1234,
      currency: 'USD'
    )
  end

  path '/api/v1/security_prices' do
    get 'List security price history referenced by family investment data' do
      tags 'Security Prices'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :security_id, in: :query, required: false,
                description: 'Filter by security ID',
                schema: { type: :string, format: :uuid }
      parameter name: :currency, in: :query, required: false,
                description: 'Filter by currency code',
                schema: { type: :string }
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter prices from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter prices until this date',
                schema: { type: :string, format: :date }
      parameter name: :provisional, in: :query, required: false,
                description: 'Filter by provisional price status. When supplied, must be true or false.',
                schema: { type: :boolean }

      response '200', 'security prices listed' do
        schema '$ref' => '#/components/schemas/SecurityPriceCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:security_id) { 'not-a-uuid' }

        run_test!
      end
    end

    post 'Upsert daily prices for a manually priced security' do
      tags 'Security Prices'
      description 'Bulk upsert of up to 2000 daily prices, keyed on (security, date, currency), so the same request can be ' \
                  'sent again. The security must be set to manual prices first (PATCH /api/v1/securities/{id}). Prices are rounded ' \
                  'to four decimal places and stored as settled. The whole request is rejected if any row is invalid. ' \
                  'Prices are shared by every family on the instance, so this needs an admin and a security the family holds or traded.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[security_id prices],
        properties: {
          security_id: { type: :string, format: :uuid },
          currency: { type: :string, description: 'ISO 4217 code, defaults to USD' },
          prices: {
            type: :array,
            minItems: 1,
            maxItems: 2000,
            items: {
              type: :object,
              required: %w[date price],
              properties: {
                date: { type: :string, format: :date, description: 'ISO 8601 date, not in the future, once per request' },
                price: { type: :string, description: 'Positive decimal, rounded to four places' }
              }
            }
          }
        }
      }

      before { security.enable_manual_prices! }
      let(:body) { { security_id: security.id, prices: [ { date: '2018-01-02', price: '21.5' }, { date: '2018-01-03', price: '21.62' } ] } }

      response '200', 'prices stored' do
        schema type: :object,
               required: %w[created updated unchanged],
               properties: {
                 created: { type: :integer },
                 updated: { type: :integer, description: 'Existing dates whose price changed' },
                 unchanged: { type: :integer, description: 'Existing dates already at that price' }
               }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope or not an admin' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'security not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { security_id: SecureRandom.uuid, prices: [ { date: '2018-01-02', price: '1' } ] } }

        run_test!
      end

      response '422', 'invalid request or security is not set to manual prices' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { security_id: security.id, prices: [] } }

        run_test!
      end
    end

    delete 'Delete a date range of a manually priced security\'s prices' do
      tags 'Security Prices'
      description 'Undoes a bad load. Both start_date and end_date are required, so there is no delete-everything call. ' \
                  'Only for securities set to manual prices; needs an admin.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      parameter name: :security_id, in: :query, required: true, schema: { type: :string, format: :uuid }
      parameter name: :start_date, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :currency, in: :query, required: false,
                description: 'Only delete prices in this currency', schema: { type: :string }

      before { security.enable_manual_prices! }
      let(:security_id) { security.id }
      let(:start_date) { '2018-01-01' }
      let(:end_date) { '2018-12-31' }

      response '200', 'prices deleted' do
        schema type: :object,
               required: %w[deleted],
               properties: { deleted: { type: :integer } }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope or not an admin' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'missing bound or security is not set to manual prices' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:end_date) { nil }

        run_test!
      end
    end
  end

  path '/api/v1/security_prices/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Security price ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve a security price referenced by family investment data' do
      tags 'Security Prices'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { security_price.id }

      response '200', 'security price retrieved' do
        schema '$ref' => '#/components/schemas/SecurityPrice'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'security price not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
