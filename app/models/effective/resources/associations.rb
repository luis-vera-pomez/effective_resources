module Effective
  module Resources
    module Associations

      def macros
        [:belongs_to, :belongs_to_polymorphic, :has_many, :has_and_belongs_to_many, :has_one]
      end

      def belong_tos
        return [] unless klass.respond_to?(:reflect_on_all_associations)
        @belong_tos ||= klass.reflect_on_all_associations(:belongs_to)
      end

      def has_ones
        return [] unless klass.respond_to?(:reflect_on_all_associations)
        @has_ones ||= klass.reflect_on_all_associations(:has_one)
      end

      def has_manys
        return [] unless klass.respond_to?(:reflect_on_all_associations)
        @has_manys ||= klass.reflect_on_all_associations(:has_many).reject { |ass| ass.options[:autosave] }
      end

      def has_and_belongs_to_manys
        return [] unless klass.respond_to?(:reflect_on_all_associations)
        @has_and_belongs_to_manys ||= klass.reflect_on_all_associations(:has_and_belongs_to_many)
      end

      def nested_resources
        return [] unless klass.respond_to?(:reflect_on_all_associations)
        @nested_resources ||= klass.reflect_on_all_associations(:has_many).select { |ass| ass.options[:autosave] }
      end

      def associated(name)
        name = (name.to_s.end_with?('_id') ? name.to_s[0...-3] : name).to_sym
        klass.reflect_on_all_associations.find { |ass| ass.name == name } || effective_addresses(name)
      end

      def belongs_to(name)
        if name.kind_of?(String) || name.kind_of?(Symbol)
          name = (name.to_s.end_with?('_id') ? name.to_s[0...-3] : name).to_sym
          belong_tos.find { |ass| ass.name == name && !ass.options[:polymorphic] }
        else
          belong_tos.find { |ass| ass.klass == name.class && !ass.options[:polymorphic] }
        end
      end

      def belongs_to_polymorphic(name)
        name = (name.to_s.end_with?('_id') ? name.to_s[0...-3] : name).to_sym
        belong_tos.find { |ass| ass.name == name && ass.options[:polymorphic] }
      end

      def has_and_belongs_to_many(name)
        name = name.to_sym
        has_and_belongs_to_manys.find { |ass| ass.name == name }
      end

      def has_many(name)
        name = name.to_sym
        (has_manys + nested_resources).find { |ass| ass.name == name }
      end

      def has_one(name)
        name = name.to_sym
        has_ones.find { |ass| ass.name == name }
      end

      def effective_addresses(name)
        return unless defined?(EffectiveAddresses) && has_many(:addresses).try(:klass) == Effective::Address

        name = name.to_s.downcase
        return unless name.end_with?('_address') || name.end_with?('_addresses')

        category = name.split('_').reject { |name| name == 'address' || name == 'addresses' }.join('_')
        return unless category.present?

        Effective::Address.where(category: category).where(addressable_type: class_name)
      end

      def nested_resource(name)
        name = name.to_sym
        nested_resources.find { |ass| ass.name == name }
      end

      def scope?(name)
        return false unless klass.respond_to?(name)

        is_scope = false

        ActiveRecord::Base.transaction do
          begin
            relation = klass.public_send(name).kind_of?(ActiveRecord::Relation)
          rescue => e
          end

          raise ActiveRecord::Rollback
        end

        is_scope
      end

    end
  end
end




