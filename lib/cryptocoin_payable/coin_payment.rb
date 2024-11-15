require 'money-tree'
require 'state_machines-activerecord'

module CryptocoinPayable
  class CoinPayment < ActiveRecord::Base
    belongs_to :payable, polymorphic: true
    has_many :transactions, class_name: 'CryptocoinPayable::CoinPaymentTransaction'

    validates :reason, presence: true
    validates :price, presence: true
    validates :coin_type, presence: true

    before_create :populate_currency_and_amount_due
    after_create :populate_address
    after_create :create_qrcode, if: -> { CryptocoinPayable.configuration.qrcode? }

    scope :unconfirmed, -> { where(state: %i[pending partial_payment paid_in_full]) }
    scope :unpaid, -> { where(state: %i[pending partial_payment]) }
    scope :stale, -> { where('updated_at < ? OR coin_amount_due = 0', 30.minutes.ago) }

    # TODO: Duplicated in `CurrencyConversion`.
    enum :coin_type, %i[
      btc
      eth
      bch
    ]

    state_machine :state, initial: :pending do
      state :pending
      state :partial_payment
      state :paid_in_full
      state :confirmed
      state :comped
      state :expired

      after_transition on: :pay, do: :notify_payable_paid
      after_transition on: :comp, do: :notify_payable_paid
      after_transition on: :partially_pay, do: :notify_payable_partially_paid
      after_transition on: :confirm, do: :notify_payable_confirmed
      after_transition on: :expire, do: :notify_payable_expired

      event :pay do
        transition %i[pending partial_payment] => :paid_in_full
      end

      event :partially_pay do
        transition pending: :partial_payment
      end

      event :comp do
        transition %i[pending partial_payment] => :comped
      end

      event :confirm do
        transition paid_in_full: :confirmed
      end

      event :expire do
        transition [:pending] => :expired
      end
    end

    def coin_amount_due_main
      adapter.convert_subunit_to_main(coin_amount_due)
    end
    def coin_amount_paid
      transactions.sum { |tx| adapter.convert_subunit_to_main(tx.estimated_value) }
    end

    def coin_amount_paid_subunit
      transactions.sum(&:estimated_value)
    end

    # @returns cents in fiat currency.
    def currency_amount_paid
      cents = transactions.inject(0) do |sum, tx|
        sum + (adapter.convert_subunit_to_main(tx.estimated_value) * tx.coin_conversion)
      end

      # Round to 0 decimal places so there aren't any partial cents.
      cents.round(0)
    end

    def currency_amount_due
      price - currency_amount_paid
    end

    def calculate_coin_amount_due
      adapter.convert_main_to_subunit(currency_amount_due / coin_conversion.to_f).ceil
    end

    def coin_conversion
      @coin_conversion ||= CurrencyConversion.where(coin_type: coin_type).last.price
    end

    def expired_at
      created_at&.+(CryptocoinPayable.configuration.expire_payments_after)
    end

    def update_coin_amount_due(rate: coin_conversion)
      update!(
        coin_amount_due: calculate_coin_amount_due,
        coin_conversion: rate
      )
    end

    def transactions_confirmed?
      transactions.all? do |t|
        t.confirmations >= CryptocoinPayable.configuration.send(coin_type).confirmations
      end
    end

    def adapter
      @adapter ||= Adapters.for(coin_type)
    end

    private

    def populate_currency_and_amount_due
      self.currency ||= CryptocoinPayable.configuration.currency
      self.coin_amount_due = calculate_coin_amount_due
      self.coin_conversion = coin_conversion
    end

    def populate_address
      update(address: adapter.create_address(id))
    end

    def notify_payable_event(event_name)
      method_name = :"coin_payment_#{event_name}"
      payable.send(method_name, self) if payable.respond_to?(method_name)

      payable.coin_payment_event(self, event_name) if payable.respond_to?(:coin_payment_event)
    end

    def notify_payable_paid
      notify_payable_event(:paid)
    end

    def notify_payable_partially_paid
      notify_payable_event(:partially_paid)
    end

    def notify_payable_confirmed
      notify_payable_event(:confirmed)
    end

    def notify_payable_expired
      notify_payable_event(:expired)
    end

    def create_qrcode
      # qrcode_object.write_to_file("qqrcode-#{address}.png")
      # self.qrcode.attach(qrcode_object)

      self.qrcode.attach(
        io: qrcode_object,
        filename: "#{address}.png",
        content_type: 'image/png'
      )
    end

    def qrcode_object
      @qrcode_object ||= CryptocoinPayable::QRCodes.for(coin_type)
                                                   .new(amount: coin_amount_due_main, address: , reason:,
                                                        options: CryptocoinPayable.configuration.qrcode)
                                                   .generate
    end

  end
end