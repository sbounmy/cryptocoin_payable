[![Gem Version](https://badge.fury.io/rb/cryptocoin_payable.svg)](https://badge.fury.io/rb/cryptocoin_payable)
[![Build Status](https://travis-ci.com/Sailias/cryptocoin_payable.svg?branch=master)](https://travis-ci.com/Sailias/cryptocoin_payable)

# Cryptocoin Payable

Forked from [Bitcoin Payable](https://github.com/Sailias/bitcoin_payable)

A rails gem that enables any model to have cryptocurrency payments.
The polymorphic table coin_payments creates payments with unique addresses based on a BIP32 deterministic seed using https://github.com/GemHQ/money-tree and uses external APIs to check for payments:

- https://etherscan.io
- https://blockexplorer.com
- https://www.blockcypher.com

Supported coins are:

- Bitcoin
- Bitcoin Cash
- Ethereum

Payments have the following states:

- `pending`
- `partial_payment`
- `paid_in_full`
- `comped` (useful for refunding payments)
- `confirmed` (enters state after n blockchain confirmations, see `confirmations` config option)
- `expired` (useful for auto-expiring incomplete payments, see `expire_payments_after` config option)

No private keys needed, No bitcoind blockchain indexing on new servers, just address and payments.

**Donations appreciated**

- `14xXZ6SFjwYZHATiywBE2durFknLePYqHS` (Maros Hluska)

## Installation

Add this line to your application's Gemfile:

```rb
gem 'cryptocoin_payable'
```

And then execute:

```sh
bundle
rails g cryptocoin_payable:install
bundle exec rake db:migrate
populate cryptocoin_payable.rb (see below)
bundle exec rake cryptocoin_payable:process_prices (see below)
```

## Uninstall

```sh
rails d cryptocoin_payable:install
```

## Build Docker
```
docker-compose up --build
```

## Run Tests


```sh
docker-compose run web bin/cucumber features
docker-compose run web rspec
docker-compose run web rubocop
```

if you get an error about the database tables not being created, run:

```sh
cd spec/dummy
RAILS_ENV=test bin/rails db:schema:load
```

## Usage

### Configuration

config/initializers/cryptocoin_payable.rb

```rb
CryptocoinPayable.configure do |config|
  # config.currency = :usd
  # config.testnet = true

  config.request_delay = 0.5
  config.expire_payments_after = 15.minutes

  # defaults to STDOUT
  # config.logger = Rails.logger 
  
  config.configure_btc do |btc_config|
    # btc_config.confirmations = 3
    # btc_config.node_path = ''

    btc_config.master_public_key = 'tpub...'
  end

  config.configure_bch do |bch_config|
    # bch_config.confirmations = 3
    # btc_config.node_path = ''

    bch_config.master_public_key = 'tpub...'
  end

  config.configure_eth do |eth_config|
    # eth_config.confirmations = 12
    # eth_config.node_path = ''

    eth_config.master_public_key = 'tpub...'
  end
end
```

In order to use the bitcoin network and issue real addresses, `CryptocoinPayable.config.testnet` must be set to false:

```rb
CryptocoinPayable.config.testnet = false
```

Consider adding a request delay (in seconds) to prevent API rate limit errors:

```rb
CryptocoinPayable.config.request_delay = 0.5
```

#### Node Path

The derivation path for the node that will be creating your addresses.

#### Master Public Key

A BIP32 MPK in "Extended Key" format used when configuring bitcoin payments (see `btc_config.master_public_key` above).

Public net starts with: xpub
Testnet starts with: tpub

* Obtain your BIP32 MPK from http://bip32.org/

### Adding it to your model

```rb
class Product < ActiveRecord::Base
  has_coin_payments
end
```

### Creating a payment from your application

```rb
def create_payment(amount_in_cents)
  self.coin_payments.create!(reason: 'sale', price: amount_in_cents, coin_type: :btc)
end
```

### Update payments with the current price of BTC based on your currency

CryptocoinPayable also supports local currency conversions and BTC exchange rates.

The `process_prices` rake task connects to api.coinbase.com to get the latest BTC price for your specified currency. As a fallback, it will connect to api.gemini.com to get the latest price.
It then updates all payments that havent received an update in the last 30 minutes with the new value owing in BTC.
This *honors* the price of a payment for 30 minutes at a time.

```sh
rake cryptocoin_payable:process_prices
```

### Processing payments

All payments are calculated against the dollar amount of the payment.  So a `bitcoin_payment` for $49.99 will have it's value calculated in BTC.
It will stay at that price for 30 minutes.  When a payment is made, a transaction is created that stores the BTC in satoshis paid and the exchange rate is was paid at.
This is very valuable for accounting later.  (capital gains of all payments received)

If a partial payment is made, the BTC value is recalculated for the remaining *dollar* amount with the latest exchange rate.
This means that if someone pays 0.01 for a 0.5 payment, that 0.01 is converted into dollars at the time of processing and the
remaining amount is calculated in dollars and the remaining amount in BTC is issued.  (If BTC bombs, that value could be greater than 0.5 now)

This prevents people from gaming the payments by paying very little BTC in hopes the price will rise.
Payments are not recalculated based on the current value of BTC, but in dollars.

To run the payment processor:

```sh
rake cryptocoin_payable:process_payments
```

### Notify your application when a payment is made

Use the `coin_payment_partially_paid`, `coin_payment_paid` and `coin_payment_confirmed` methods

```rb
def Product < ActiveRecord::Base
  has_coin_payments

  def create_payment(amount_in_cents)
    self.coin_payments.create!(reason: 'sale', price: amount_in_cents, type: :btc)
  end

  # Runs when the payment is first detected on the network.
  def coin_payment_paid(payment)
    self.notify!
  end

  # Runs when the payment is partially paid
  def coin_payment_partially_paid(payment)
    self.awaiting_full_payment!
  end

  # Runs when enough confirmations have occurred.
  def coin_payment_confirmed(payment)
    self.ship!
  end
end
```

### Delete old CurrencyConversion data

Every time the payment processor is run, several rows are inserted into the
database to record the value of the coin at a given instance in time. Over time,
your application will accumulate historical currency conversion data and you may
want to clear it out:

```sh
rake cryptocoin_payable:delete_currency_conversions
```

By default, it will delete any data older than 1 month. You can configure this
using an env variable:

```sh
DELETE_BEFORE=2017-12-15 rake cryptocoin_payable:delete_currency_conversions
```

### Comp a payment

This will bypass the payment, set the state to comped and call back to your app that the payment has been processed.

```rb
@coin_payment.comp
```

### Expire a payment

```rb
@coin_payment.expire
```

Payments will auto-expire if you set the `expire_payments_after` option. The
exact timing is not precise because payment expiry is evaluated whenever
payment_processor runs.

### View all the transactions in the payment

```rb
coin_payment = @product.coin_payments.first
coin_payment.transactions.find_each do |transaction|
  puts transaction.attributes
end
```

### QRCode generation

Only supports bitcoin using BIP-21 at the moment
```rb

# initializers/cryptocoin_payable.rb
require 'chunky_png'

CryptocoinPayable.configure do |config|
  config.qrcode = { bit_depth: 1,
                      border_modules: 4,
                      color_mode: ChunkyPNG::COLOR_GRAYSCALE,
                      color: 'black',
                      file: nil,
                      fill: 'white',
                      module_px_size: 6,
                      resize_exactly_to: false,
                      resize_gte_to: false,
                      size: 1200 }
end
```

or if you dont want qrcode generation

```rb
config.qrcode = nil 
```

Display the qrcode 
```rb
<%= image_tag coin_payment.qrcode, width: 250 %>
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## Contributors

* andersonlewin
* krtschmr
* mhluska