require 'spec_helper'

module Spree
  describe LineItem do
    describe "scopes" do
      let(:o) { create(:order) }

      let(:s1) { create(:supplier_enterprise) }
      let(:s2) { create(:supplier_enterprise) }

      let(:p1) { create(:simple_product, supplier: s1) }
      let(:p2) { create(:simple_product, supplier: s2) }

      let(:li1) { create(:line_item, order: o, product: p1) }
      let(:li2) { create(:line_item, order: o, product: p2) }

      let(:p3) { create(:product, name: 'Clear Honey') }
      let(:p4) { create(:product, name: 'Apricots') }
      let(:v1) { create(:variant, product: p3, unit_value: 500) }
      let(:v2) { create(:variant, product: p3, unit_value: 250) }
      let(:v3) { create(:variant, product: p4, unit_value: 500, display_name: "ZZ") }
      let(:v4) { create(:variant, product: p4, unit_value: 500, display_name: "aa") }
      let(:li3) { create(:line_item, order: o, product: p3, variant: v1) }
      let(:li4) { create(:line_item, order: o, product: p3, variant: v2) }
      let(:li5) { create(:line_item, order: o, product: p4, variant: v3) }
      let(:li6) { create(:line_item, order: o, product: p4, variant: v4) }

      let(:oc_order) { create :order_with_totals_and_distribution }

      it "finds line items for products supplied by one of a number of enterprises" do
        li1; li2
        expect(LineItem.supplied_by_any([s1])).to eq([li1])
        expect(LineItem.supplied_by_any([s2])).to eq([li2])
        expect(LineItem.supplied_by_any([s1, s2])).to match_array [li1, li2]
      end

      describe "finding line items with and without tax" do
        let(:tax_rate) { create(:tax_rate, calculator: Calculator::DefaultTax.new) }
        let!(:adjustment1) { create(:adjustment, originator: tax_rate, label: "TR", amount: 123, included_tax: 10.00) }

        before do
          li1
          li2
          li1.adjustments << adjustment1
        end

        it "finds line items with tax" do
          expect(LineItem.with_tax).to eq([li1])
        end

        it "finds line items without tax" do
          expect(LineItem.without_tax).to eq([li2])
        end
      end

      it "finds line items sorted by name and unit_value" do
        expect(o.line_items.sorted_by_name_and_unit_value).to eq([li6, li5, li4, li3])
      end

      it "finds line items from a given order cycle" do
        expect(LineItem.from_order_cycle(oc_order.order_cycle).first.id).to eq oc_order.line_items.first.id
      end
    end

    describe "capping quantity at stock level" do
      let!(:v) { create(:variant, on_demand: false, on_hand: 10) }
      let!(:li) { create(:line_item, variant: v, quantity: 10, max_quantity: 10) }

      before do
        v.update! on_hand: 5
      end

      it "caps quantity" do
        li.cap_quantity_at_stock!
        expect(li.reload.quantity).to eq 5
      end

      it "does not cap max_quantity" do
        li.cap_quantity_at_stock!
        expect(li.reload.max_quantity).to eq 10
      end

      it "works for products without max_quantity" do
        li.update_column :max_quantity, nil
        li.cap_quantity_at_stock!
        li.reload
        expect(li.quantity).to eq 5
        expect(li.max_quantity).to be nil
      end

      it "does nothing for on_demand items" do
        v.update! on_demand: true
        li.cap_quantity_at_stock!
        li.reload
        expect(li.quantity).to eq 10
        expect(li.max_quantity).to eq 10
      end

      it "caps at zero when stock is negative" do
        v.__send__(:stock_item).update_column(:count_on_hand, -2)
        li.cap_quantity_at_stock!
        expect(li.reload.quantity).to eq 0
      end

      context "when a variant override is in place" do
        let!(:hub) { create(:distributor_enterprise) }
        let!(:vo) { create(:variant_override, hub: hub, variant: v, count_on_hand: 2) }

        before do
          li.order.update(distributor_id: hub.id)

          # li#scoper is memoised, and this makes it difficult to update test conditions
          # so we reset it after the line_item is created for each spec
          li.remove_instance_variable(:@scoper)
        end

        it "caps quantity to override stock level" do
          li.cap_quantity_at_stock!
          expect(li.quantity).to eq 2
        end

        context "when count on hand is negative" do
          before { vo.update(count_on_hand: -3) }

          it "caps at zero" do
            v.__send__(:stock_item).update_column(:count_on_hand, -2)
            li.cap_quantity_at_stock!
            expect(li.reload.quantity).to eq 0
          end
        end
      end
    end

    describe "reducing stock levels on order completion" do
      context "when the item is on_demand" do
        let!(:hub) { create(:distributor_enterprise) }
        let(:bill_address) { create(:address) }
        let!(:variant_on_demand) { create(:variant, on_demand: true, on_hand: 1) }
        let!(:order) {
          create(:order,
                 distributor: hub,
                 order_cycle: create(:simple_order_cycle),
                 bill_address: bill_address,
                 ship_address: bill_address)
        }
        let!(:shipping_method) { create(:shipping_method, distributors: [hub]) }
        let!(:line_item) { create(:line_item, variant: variant_on_demand, quantity: 10, order: order) }

        before do
          order.reload
          order.update_totals
          order.payments << create(:payment, amount: order.total)
          until order.completed? do break unless order.next! end
          order.payment_state = 'paid'
          order.select_shipping_method(shipping_method.id)
          order.shipment.update!(order)
        end

        it "creates a shipment without backordered items" do
          expect(order.shipment.manifest.count).to eq 1
          expect(order.shipment.manifest.first.quantity).to eq 10
          expect(order.shipment.manifest.first.states).to eq 'on_hand' => 10
          expect(order.shipment.manifest.first.variant).to eq line_item.variant
        end

        it "does not reduce the variant's stock level" do
          expect(variant_on_demand.reload.on_hand).to eq 1
        end

        it "does not mark inventory units as backorderd" do
          backordered_units = order.shipments.first.inventory_units.any?(&:backordered?)
          expect(backordered_units).to be false
        end

        it "does not mark the shipment as backorderd" do
          expect(order.shipments.first.backordered?).to be false
        end

        it "allows the order to be shipped" do
          expect(order.ready_to_ship?).to be true
        end

        it "does not change stock levels when cancelled" do
          order.cancel!
          expect(variant_on_demand.reload.on_hand).to eq 1
        end
      end
    end

    describe "tracking stock when quantity is changed" do
      context "when the order is already complete" do
        let(:shop) { create(:distributor_enterprise) }
        let(:order) { create(:completed_order_with_totals, distributor: shop) }
        let!(:line_item) { order.reload.line_items.first }
        let!(:variant) { line_item.variant }

        context "when a variant override applies" do
          let!(:vo) { create(:variant_override, hub: shop, variant: variant, count_on_hand: 3 ) }

          it "draws stock from the variant override" do
            expect(vo.reload.count_on_hand).to eq 3
            expect{ line_item.increment!(:quantity) }.to_not change{ Spree::Variant.find(variant.id).on_hand }
            expect(vo.reload.count_on_hand).to eq 2
          end
        end

        context "when a variant override does not apply" do
          it "draws stock from the variant" do
            expect{ line_item.increment!(:quantity) }.to change{ Spree::Variant.find(variant.id).on_hand }.by(-1)
          end
        end
      end
    end

    describe "tracking stock when a line item is destroyed" do
      context "when the order is already complete" do
        let(:shop) { create(:distributor_enterprise) }
        let(:order) { create(:completed_order_with_totals, distributor: shop) }
        let!(:line_item) { order.reload.line_items.first }
        let!(:variant) { line_item.variant }

        context "when a variant override applies" do
          let!(:vo) { create(:variant_override, hub: shop, variant: variant, count_on_hand: 3 ) }

          it "restores stock to the variant override" do
            expect(vo.reload.count_on_hand).to eq 3
            expect{ line_item.destroy }.to_not change{ Spree::Variant.find(variant.id).on_hand }
            expect(vo.reload.count_on_hand).to eq 4
          end
        end

        context "when a variant override does not apply" do
          it "restores stock to the variant" do
            expect{ line_item.destroy }.to change{ Spree::Variant.find(variant.id).on_hand }.by(1)
          end
        end
      end
    end

    describe "determining if sufficient stock is present" do
      let!(:hub) { create(:distributor_enterprise) }
      let!(:o) { create(:order, distributor: hub) }
      let!(:v) { create(:variant, on_demand: false, on_hand: 10) }
      let!(:v_on_demand) { create(:variant, on_demand: true, on_hand: 1) }
      let(:li) { build_stubbed(:line_item, variant: v, order: o, quantity: 5, max_quantity: 5) }
      let(:li_on_demand) { build_stubbed(:line_item, variant: v_on_demand, order: o, quantity: 99, max_quantity: 99) }

      context "when the variant is on_demand" do
        it { expect(li_on_demand.sufficient_stock?).to be true }
      end

      context "when stock on the variant is sufficient" do
        it { expect(li.sufficient_stock?).to be true }
      end

      context "when the stock on the variant is not sufficient" do
        before { v.update(on_hand: 4) }

        context "when no variant override is in place" do
          it { expect(li.sufficient_stock?).to be false }
        end

        context "when a variant override is in place" do
          let!(:vo) { create(:variant_override, hub: hub, variant: v, count_on_hand: 5) }

          context "and stock on the variant override is sufficient" do
            it { expect(li.sufficient_stock?).to be true }
          end

          context "and stock on the variant override is not sufficient" do
            before { vo.update(count_on_hand: 4) }

            it { expect(li.sufficient_stock?).to be false }
          end
        end
      end
    end

    describe "calculating price with adjustments" do
      it "does not return fractional cents" do
        li = LineItem.new

        allow(li).to receive(:price) { 55.55 }
        allow(li).to receive_message_chain(:order, :adjustments, :loaded?)
        allow(li).to receive_message_chain(:order, :adjustments, :select)
        allow(li).to receive_message_chain(:order, :adjustments, :where, :sum) { 11.11 }
        allow(li).to receive(:quantity) { 2 }
        expect(li.price_with_adjustments).to eq(61.11)
      end
    end

    describe "calculating amount with adjustments" do
      it "returns a value consistent with price_with_adjustments" do
        li = LineItem.new

        allow(li).to receive(:price) { 55.55 }
        allow(li).to receive_message_chain(:order, :adjustments, :loaded?)
        allow(li).to receive_message_chain(:order, :adjustments, :select)
        allow(li).to receive_message_chain(:order, :adjustments, :where, :sum) { 11.11 }
        allow(li).to receive(:quantity) { 2 }
        expect(li.amount_with_adjustments).to eq(122.22)
      end
    end

    describe "tax" do
      let(:li_no_tax)   { create(:line_item) }
      let(:li_tax)      { create(:line_item) }
      let(:tax_rate)    { create(:tax_rate, calculator: Calculator::DefaultTax.new) }
      let!(:adjustment) { create(:adjustment, adjustable: li_tax, originator: tax_rate, label: "TR", amount: 123, included_tax: 10.00) }

      context "checking if a line item has tax included" do
        it "returns true when it does" do
          expect(li_tax).to have_tax
        end

        it "returns false otherwise" do
          expect(li_no_tax).to_not have_tax
        end
      end

      context "calculating the amount of included tax" do
        it "returns the included tax when present" do
          expect(li_tax.included_tax).to eq 10.00
        end

        it "returns 0.00 otherwise" do
          expect(li_no_tax.included_tax).to eq 0.00
        end
      end
    end

    describe "unit value/description" do
      describe "inheriting units" do
        let!(:p) { create(:product, variant_unit: "weight", variant_unit_scale: 1, master: create(:variant, unit_value: 1000 )) }
        let!(:v) { p.variants.first }
        let!(:o) { create(:order) }

        context "on create" do
          context "when no final_weight_volume is set" do
            let(:li) { build(:line_item, order: o, variant: v, quantity: 3) }

            it "initializes final_weight_volume from the variant's unit_value" do
              expect(li.final_weight_volume).to be nil
              li.save
              expect(li.final_weight_volume).to eq 3000
            end
          end

          context "when a final_weight_volume has been set" do
            let(:li) { build(:line_item, order: o, variant: v, quantity: 3, final_weight_volume: 2000) }

            it "uses the changed value" do
              expect(li.final_weight_volume).to eq 2000
              li.save
              expect(li.final_weight_volume).to eq 2000
            end
          end
        end

        context "on save" do
          let!(:li) { create(:line_item, order: o, variant: v, quantity: 3) }

          before do
            expect(li.final_weight_volume).to eq 3000
          end

          context "when final_weight_volume is changed" do
            let(:attrs) { { final_weight_volume: 2000 } }

            context "and quantity is not changed" do
              before do
                li.update(attrs)
              end

              it "uses the value given" do
                expect(li.final_weight_volume).to eq 2000
              end
            end

            context "and quantity is changed" do
              before do
                attrs[:quantity] = 4
                li.update(attrs)
              end

              it "uses the value given" do
                expect(li.final_weight_volume).to eq 2000
              end
            end
          end

          context "when final_weight_volume is not changed" do
            let(:attrs) { { price: 3.00 } }

            context "and quantity is not changed" do
              before do
                li.update(attrs)
              end

              it "does not change final_weight_volume" do
                expect(li.final_weight_volume).to eq 3000
              end
            end

            context "and quantity is changed" do
              context "from > 0" do
                context "and a final_weight_volume has been set" do
                  before do
                    expect(li.final_weight_volume).to eq 3000
                    attrs[:quantity] = 4
                    li.update(attrs)
                  end

                  it "scales the final_weight_volume based on the change in quantity" do
                    expect(li.final_weight_volume).to eq 4000
                  end
                end

                context "and a final_weight_volume has not been set" do
                  before do
                    li.update(final_weight_volume: nil)
                    attrs[:quantity] = 1
                    li.update(attrs)
                  end

                  it "calculates a final_weight_volume from the variants unit_value" do
                    expect(li.final_weight_volume).to eq 1000
                  end
                end
              end

              context "from 0" do
                before { li.update(quantity: 0) }

                context "and a final_weight_volume has been set" do
                  before do
                    expect(li.final_weight_volume).to eq 0
                    attrs[:quantity] = 4
                    li.update(attrs)
                  end

                  it "recalculates a final_weight_volume from the variants unit_value" do
                    expect(li.final_weight_volume).to eq 4000
                  end
                end

                context "and a final_weight_volume has not been set" do
                  before do
                    li.update(final_weight_volume: nil)
                    attrs[:quantity] = 1
                    li.update(attrs)
                  end

                  it "calculates a final_weight_volume from the variants unit_value" do
                    expect(li.final_weight_volume).to eq 1000
                  end
                end
              end
            end
          end
        end
      end

      describe "generating the full name" do
        let(:li) { LineItem.new }

        context "when display_name is blank" do
          before do
            allow(li).to receive(:unit_to_display) { 'unit_to_display' }
            allow(li).to receive(:display_name) { '' }
          end

          it "returns unit_to_display" do
            expect(li.full_name).to eq('unit_to_display')
          end
        end

        context "when unit_to_display contains display_name" do
          before do
            allow(li).to receive(:unit_to_display) { '1kg Jar' }
            allow(li).to receive(:display_name) { '1kg' }
          end

          it "returns unit_to_display" do
            expect(li.full_name).to eq('1kg Jar')
          end
        end

        context "when display_name contains unit_to_display" do
          before do
            allow(li).to receive(:unit_to_display) { '10kg' }
            allow(li).to receive(:display_name) { '10kg Box' }
          end

          it "returns display_name" do
            expect(li.full_name).to eq('10kg Box')
          end
        end

        context "otherwise" do
          before do
            allow(li).to receive(:unit_to_display) { '1 Loaf' }
            allow(li).to receive(:display_name) { 'Spelt Sourdough' }
          end

          it "returns unit_to_display" do
            expect(li.full_name).to eq('Spelt Sourdough (1 Loaf)')
          end
        end
      end

      describe "generating the product and variant name" do
        let(:li) { LineItem.new }
        let(:p) { double(:product, name: 'product') }
        before { allow(li).to receive(:product) { p } }

        context "when full_name starts with the product name" do
          before { allow(li).to receive(:full_name) { p.name + " - something" } }

          it "does not show the product name twice" do
            expect(li.product_and_full_name).to eq('product - something')
          end
        end

        context "when full_name does not start with the product name" do
          before { allow(li).to receive(:full_name) { "display_name (unit)" } }

          it "prepends the product name to the full name" do
            expect(li.product_and_full_name).to eq('product - display_name (unit)')
          end
        end
      end

      describe "getting name for display" do
        it "returns product name" do
          li = build_stubbed(:line_item)
          expect(li.name_to_display).to eq(li.product.name)
        end
      end

      describe "getting unit for display" do
        let(:o) { create(:order) }
        let(:p1) { create(:product, name: 'Clear Honey', variant_unit_scale: 1) }
        let(:v1) { create(:variant, product: p1, unit_value: 500) }
        let(:li1) { create(:line_item, order: o, product: p1, variant: v1) }
        let(:p2) { create(:product, name: 'Clear United States Honey', variant_unit_scale: 453.6) }
        let(:v2) { create(:variant, product: p2, unit_value: 453.6) }
        let(:li2) { create(:line_item, order: o, product: p2, variant: v2) }

        it "returns options_text" do
          li = build_stubbed(:line_item)
          allow(li).to receive(:options_text).and_return "ponies"
          expect(li.unit_to_display).to eq("ponies")
        end

        it "returns options_text based on units" do
          expect(li1.options_text).to eq("500g")
          expect(li2.options_text).to eq("1lb")
        end
      end

      context "when the line_item already has a final_weight_volume set (and all required option values do not exist)" do
        let!(:p0) { create(:simple_product, variant_unit: 'weight', variant_unit_scale: 1) }
        let!(:v) { create(:variant, product: p0, unit_value: 10, unit_description: 'bar') }

        let!(:p) { create(:simple_product, variant_unit: 'weight', variant_unit_scale: 1) }
        let!(:li) { create(:line_item, product: p, final_weight_volume: 5) }

        it "removes the old option value and assigns the new one" do
          ov_orig = li.option_values.last
          ov_var  = v.option_values.last
          allow(li).to receive(:unit_description) { 'foo' }

          expect {
            li.update_attribute(:final_weight_volume, 10)
          }.to change(Spree::OptionValue, :count).by(1)

          expect(li.option_values).not_to include ov_orig
          expect(li.option_values).not_to include ov_var
          ov = li.option_values.last
          expect(ov.name).to eq("10g foo")
        end
      end

      context "when the variant already has a value set (and all required option values exist)" do
        let!(:p0) { create(:simple_product, variant_unit: 'weight', variant_unit_scale: 1) }
        let!(:v) { create(:variant, product: p0, unit_value: 10, unit_description: 'bar') }

        let!(:p) { create(:simple_product, variant_unit: 'weight', variant_unit_scale: 1) }
        let!(:li) { create(:line_item, product: p, final_weight_volume: 5) }

        it "removes the old option value and assigns the new one" do
          ov_orig = li.option_values.last
          ov_new  = v.option_values.last
          allow(li).to receive(:unit_description) { 'bar' }

          expect {
            li.update_attribute(:final_weight_volume, 10)
          }.to change(Spree::OptionValue, :count).by(0)

          expect(li.option_values).not_to include ov_orig
          expect(li.option_values).to     include ov_new
        end
      end

      describe "calculating unit_value" do
        let(:v) { build_stubbed(:variant, unit_value: 10) }
        let(:li) { build_stubbed(:line_item, variant: v, quantity: 5) }

        context "when the quantity is greater than zero" do
          context "and final_weight_volume has not been changed" do
            it "returns the unit_value of the variant" do
              # Though note that this has been calculated
              # backwards from the final_weight_volume
              expect(li.unit_value).to eq 10
            end
          end

          context "and final_weight_volume has been changed" do
            before do
              li.final_weight_volume = 35
            end
            it "returns the unit_value of the variant" do
              expect(li.unit_value).to eq 7
            end
          end

          context "and final_weight_volume is nil" do
            before do
              li.final_weight_volume = nil
            end
            it "returns the unit_value of the variant" do
              expect(li.unit_value).to eq 10
            end
          end
        end

        context "when the quantity is zero" do
          before do
            li.quantity = 0
          end
          it "returns the unit_value of the variant" do
            expect(li.unit_value).to eq 10
          end
        end
      end
    end

    describe "deleting unit option values" do
      let!(:p) { create(:simple_product, variant_unit: 'weight', variant_unit_scale: 1) }
      let!(:ot) { Spree::OptionType.find_by name: 'unit_weight' }
      let!(:li) { create(:line_item, product: p) }

      it "removes option value associations for unit option types" do
        expect {
          li.delete_unit_option_values
        }.to change(li.option_values, :count).by(-1)
      end

      it "does not delete option values" do
        expect {
          li.delete_unit_option_values
        }.to change(Spree::OptionValue, :count).by(0)
      end
    end

    describe "when the associated variant is soft-deleted" do
      let!(:variant) { create(:variant) }
      let!(:line_item) { create(:line_item, variant: variant) }

      it "returns the associated variant or product" do
        line_item.variant.delete

        expect(line_item.variant).to eq variant
        expect(line_item.product).to eq variant.product
      end
    end
  end
end
