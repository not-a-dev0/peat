# encoding: UTF-8
# frozen_string_literal: true

describe Matching::Executor do
  let(:alice)  { who_is_billionaire }
  let(:bob)    { who_is_billionaire }
  let(:market) { Market.find('btcusd') }
  let(:price)  { 10.to_d }
  let(:volume) { 5.to_d }

  subject do
    Matching::Executor.new(
      market_id:    market.id,
      ask_id:       ask.id,
      bid_id:       bid.id,
      strike_price: price.to_s('F'),
      volume:       volume.to_s('F'),
      funds:        (price * volume).to_s('F')
    )
  end

  context 'invalid volume' do
    let(:ask) { ::Matching::LimitOrder.new create(:order_ask, price: price, volume: volume, member: alice).to_matching_attributes }
    let(:bid) { ::Matching::LimitOrder.new create(:order_bid, price: price, volume: 3.to_d, member: bob).to_matching_attributes }

    it 'should raise error' do
      expect { subject.execute! }.to raise_error(Matching::TradeExecutionError)
    end
  end

  context 'invalid price' do
    let(:ask) { ::Matching::LimitOrder.new create(:order_ask, price: price, volume: volume, member: alice).to_matching_attributes }
    let(:bid) { ::Matching::LimitOrder.new create(:order_bid, price: price - 1, volume: volume, member: bob).to_matching_attributes }

    it 'should raise error' do
      expect { subject.execute! }.to raise_error(Matching::TradeExecutionError)
    end
  end

  context 'full execution' do
    let(:ask) { ::Matching::LimitOrder.new create(:order_ask, price: price, volume: volume, member: alice).to_matching_attributes }
    let(:bid) { ::Matching::LimitOrder.new create(:order_bid, price: price, volume: volume, member: bob).to_matching_attributes }

    it 'should create trade' do
      expect do
        trade = subject.execute!

        expect(trade.trend).to eq 'up'
        expect(trade.price).to eq price
        expect(trade.volume).to eq volume
        expect(trade.ask_id).to eq ask.id
        expect(trade.bid_id).to eq bid.id
      end.to change(Trade, :count).by(1)
    end

    it 'should set trend to down' do
      Market.any_instance.expects(:latest_price).returns(11.to_d)
      trade = subject.execute!
      expect(trade.trend).to eq 'down'
    end

    it 'should set trade used funds' do
      Market.any_instance.expects(:latest_price).returns(11.to_d)
      trade = subject.execute!
      expect(trade.funds).to eq price * volume
    end

    it 'should increase order\'s trades count' do
      subject.execute!
      expect(Order.find(ask.id).trades_count).to eq 1
      expect(Order.find(bid.id).trades_count).to eq 1
    end

    it 'should mark both orders as done' do
      subject.execute!
      expect(Order.find(ask.id).state).to eq Order::DONE
      expect(Order.find(bid.id).state).to eq Order::DONE
    end

    it 'should publish trade through amqp' do
      AMQPQueue.expects(:publish)
      subject.execute!
    end
  end

  context 'partial ask execution' do
    let(:ask) { create(:order_ask, price: price, volume: 7.to_d, member: alice) }
    let(:bid) { create(:order_bid, price: price, volume: 5.to_d, member: bob) }

    it 'should set bid to done only' do
      subject.execute!

      expect(ask.reload.state).not_to eq Order::DONE
      expect(bid.reload.state).to eq Order::DONE
    end
  end

  context 'partial bid execution' do
    let(:ask) { create(:order_ask, price: price, volume: 5.to_d, member: alice) }
    let(:bid) { create(:order_bid, price: price, volume: 7.to_d, member: bob) }

    it 'should set ask to done only' do
      subject.execute!

      expect(ask.reload.state).to eq Order::DONE
      expect(bid.reload.state).not_to eq Order::DONE
    end
  end

  context 'partially filled market order whose locked fund run out' do
    let(:ask) { create(:order_ask, price: '2.0'.to_d, volume: '3.0'.to_d, member: alice) }
    let(:bid) { create(:order_bid, price: nil, ord_type: 'market', volume: '2.0'.to_d, locked: '3.0'.to_d, member: bob) }

    it 'should cancel the market order' do
      executor = Matching::Executor.new(
        market_id:    market.id,
        ask_id:       ask.id,
        bid_id:       bid.id,
        strike_price: '2.0'.to_d,
        volume:       '1.5'.to_d,
        funds:        '3.0'.to_d
      )
      executor.execute!

      expect(bid.reload.state).to eq Order::CANCEL
    end
  end

  context 'unlock not used funds' do
    let(:ask) { create(:order_ask, price: price - 1, volume: 7.to_d, member: alice) }
    let(:bid) { create(:order_bid, price: price, volume: volume, member: bob) }

    subject do
      Matching::Executor.new(
        market_id:    market.id,
        ask_id:       ask.id,
        bid_id:       bid.id,
        strike_price: price - 1, # so bid order only used (price-1)*volume
        volume:       volume.to_s('F'),
        funds:        ((price - 1) * volume).to_s('F')
      )
    end

    it 'should unlock funds not used by bid order' do
      locked_before = bid.hold_account.reload.locked

      subject.execute!
      locked_after = bid.hold_account.reload.locked

      expect(locked_after).to eq locked_before - (price * volume)
    end

    it 'should save unused amount in order locked attribute' do
      subject.execute!
      expect(bid.reload.locked).to eq price * volume - (price - 1) * volume
    end
  end

  context 'execution fail' do
    let(:ask) { ::Matching::LimitOrder.new create(:order_ask, price: price, volume: volume, member: alice).to_matching_attributes }
    let(:bid) { ::Matching::LimitOrder.new create(:order_bid, price: price, volume: volume, member: bob).to_matching_attributes }

    it 'should not create trade' do
      # set locked funds to 0 so strike will fail
      alice.get_account(:btc).update_attributes(locked: ::Trade::ZERO)

      expect do
        expect { subject.execute! }.to raise_error(Account::AccountError)
      end.not_to change(Trade, :count)
    end
  end

  context 'dynamic fees' do
    context 'when paying fee with utility currency' do
      let(:ask) { create(:order_ask, price: price, volume: volume, member: alice, fee_currency_id: 'trst') }
      let(:bid) { create(:order_bid, price: price, volume: volume, member: bob) }

      it 'detects if it is possible' do
        expect(ask.utility_fee?).to be true
        expect(bid.utility_fee?).to be false

        ask.fee_currency_account.update(balance: 0)
        expect(ask.utility_fee_possible?).to be false
        expect(bid.utility_fee_possible?).to be false

        ask.fee_currency_account.update(balance: 0.5)
        expect(ask.utility_fee_possible?).to be true
        expect(bid.utility_fee_possible?).to be false
      end
    end

    context 'when trading with enough coins on ask utility account', dynamic_fees: true do
      let(:ask) do
        create(:order_ask, price: price, volume: volume, member: alice, fee_currency_id: 'trst').tap do |ask_order|
          # load some utility tokens
          ask_order.fee_currency_account.update(balance: 1)
        end
      end
      let(:bid) { create(:order_bid, price: price, volume: volume, member: bob) }

      subject do
        Matching::Executor.new(
          market_id: market.id,
          ask_id: ask.id,
          bid_id: bid.id,
          strike_price: price.to_s('F'),
          volume: volume.to_s('F'),
          funds: (price * volume).to_s('F')
        )
      end

      it 'pays the ask trading fee with utility currency' do
        expect {
          subject.execute!

          ask.reload
          bid.reload
        }.to change { ask.expect_account.balance }.by(volume * price)
         .and change { bid.expect_account.balance }.by(ask.volume * (1.0 - ask.fee))
         .and change { ask.fee_currency_account.balance }.by(-0.5 * volume * price * bid.fee)
      end
    end

    context 'when trading with enough coins on both utility accounts', dynamic_fees: true do
      let(:ask) do
        create(:order_ask, price: price, volume: volume, member: alice, fee_currency_id: 'trst').tap do |ask_order|
          # load some utility tokens
          ask_order.fee_currency_account.update(balance: 1)
        end
      end
      let(:bid) do
        create(:order_bid, price: price, volume: volume, member: bob, fee_currency_id: 'trst').tap do |bid_order|
          # load some utility tokens
          bid_order.fee_currency_account.update(balance: 1)
        end
      end

      subject do
        Matching::Executor.new(
          market_id: market.id,
          ask_id: ask.id,
          bid_id: bid.id,
          strike_price: price.to_s('F'),
          volume: volume.to_s('F'),
          funds: (price * volume).to_s('F')
        )
      end

      it 'pays both sides trading fee with utility currency' do
        expect {
          subject.execute!

          ask.reload
          bid.reload
        }.to change { ask.expect_account.balance }.by(volume * price)
         .and change { bid.expect_account.balance }.by(volume)
         .and change { ask.fee_currency_account.balance }.by(-0.5 * volume * price * bid.fee)
         .and change { bid.fee_currency_account.balance }.by(-0.5 * volume * ask.fee)
      end
    end
  end
end
