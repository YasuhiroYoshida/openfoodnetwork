require 'ffaker'

FactoryBot.define do
  factory :classification, class: Spree::Classification do
  end

  factory :exchange, class: Exchange do
    incoming    false
    order_cycle { OrderCycle.first || FactoryBot.create(:simple_order_cycle) }
    sender      { incoming ? FactoryBot.create(:enterprise) : order_cycle.coordinator }
    receiver    { incoming ? order_cycle.coordinator : FactoryBot.create(:enterprise) }
  end

  factory :schedule, class: Schedule do
    sequence(:name) { |n| "Schedule #{n}" }

    transient do
      order_cycles { [OrderCycle.first || create(:simple_order_cycle)] }
    end

    before(:create) do |schedule, evaluator|
      evaluator.order_cycles.each do |order_cycle|
        order_cycle.schedules << schedule
      end
    end
  end

  factory :proxy_order, class: ProxyOrder do
    subscription
    order_cycle { subscription.order_cycles.first }
    before(:create) do |proxy_order, _proxy|
      proxy_order.order&.update_attribute(:order_cycle_id, proxy_order.order_cycle_id)
    end
  end

  factory :variant_override, class: VariantOverride do
    price 77.77
    on_demand false
    count_on_hand 11_111
    default_stock 2000
    resettable false

    trait :on_demand do
      on_demand true
      count_on_hand nil
    end

    trait :use_producer_stock_settings do
      on_demand nil
      count_on_hand nil
    end
  end

  factory :inventory_item, class: InventoryItem do
    enterprise
    variant
    visible true
  end

  factory :enterprise_relationship do
  end

  factory :enterprise_role do
  end

  factory :enterprise_group, class: EnterpriseGroup do
    name 'Enterprise group'
    sequence(:permalink) { |n| "group#{n}" }
    description 'this is a group'
    on_front_page false
    address { FactoryBot.build(:address) }
  end

  factory :enterprise_fee, class: EnterpriseFee do
    transient { amount nil }

    sequence(:name) { |n| "Enterprise fee #{n}" }
    sequence(:fee_type) { |n| EnterpriseFee::FEE_TYPES[n % EnterpriseFee::FEE_TYPES.count] }

    enterprise { Enterprise.first || FactoryBot.create(:supplier_enterprise) }
    calculator { build(:calculator_per_item, preferred_amount: amount) }

    after(:create) { |ef| ef.calculator.save! }

    trait :flat_rate do
      transient { amount 1 }
      calculator { build(:calculator_flat_rate, preferred_amount: amount) }
    end

    trait :per_item do
      transient { amount 1 }
      calculator { build(:calculator_per_item, preferred_amount: amount) }
    end
  end

  factory :adjustment_metadata, class: AdjustmentMetadata do
    adjustment { FactoryBot.create(:adjustment) }
    enterprise { FactoryBot.create(:distributor_enterprise) }
    fee_name 'fee'
    fee_type 'packing'
    enterprise_role 'distributor'
  end

  factory :line_item_with_shipment, parent: :line_item do
    transient do
      shipping_fee 3
      shipping_method nil
    end

    after(:build) do |line_item, evaluator|
      shipment = line_item.order.reload.shipments.first
      if shipment.nil?
        shipping_method = evaluator.shipping_method
        unless shipping_method
          shipping_method = create(:shipping_method_with, :shipping_fee, shipping_fee: evaluator.shipping_fee)
          shipping_method.distributors << line_item.order.distributor if line_item.order.distributor
        end
        shipment = create(:shipment_with, :shipping_method, shipping_method: shipping_method,
                                                            order: line_item.order)
      end
      line_item.target_shipment = shipment
    end
  end

  factory :zone_with_member, parent: :zone do
    default_tax true

    after(:create) do |zone|
      Spree::ZoneMember.create!(zone: zone, zoneable: Spree::Country.find_by(name: 'Australia'))
    end
  end

  factory :producer_property, class: ProducerProperty do
    value 'abc123'
    producer { create(:supplier_enterprise) }
    property
  end

  factory :customer, class: Customer do
    email { Faker::Internet.email }
    enterprise
    code { SecureRandom.base64(150) }
    user
    bill_address { create(:address) }
  end

  # A card that has been added to the user's profile and can be re-used.
  factory :stored_credit_card, parent: :credit_card do
    gateway_customer_profile_id "cus_F2T..."
    gateway_payment_profile_id "card_1EY..."
  end

  factory :stripe_payment_method, class: Spree::Gateway::StripeConnect do
    name 'Stripe'
    environment 'test'
    distributors { [FactoryBot.create(:enterprise)] }
    preferred_enterprise_id { distributors.first.id }
  end

  factory :stripe_sca_payment_method, class: Spree::Gateway::StripeSCA do
    name 'StripeSCA'
    environment 'test'
    distributors { [FactoryBot.create(:stripe_account).enterprise] }
    preferred_enterprise_id { distributors.first.id }
  end

  factory :stripe_account do
    enterprise { FactoryBot.create(:distributor_enterprise) }
    stripe_user_id "abc123"
    stripe_publishable_key "xyz456"
  end
end
