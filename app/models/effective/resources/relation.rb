module Effective
  module Resources
    module Relation
      attr_reader :relation

      # When Effective::Resource is initialized with an ActiveRecord relation, the following
      # methods will be available to operate on that relation, and be chainable and such

      # name: sort by this column, or this relation
      # sort: when a symbol or boolean, this is the relation's column to sort by

      def order(name, direction = :asc, as: nil, sort: nil, sql_column: nil, limit: nil, reorder: false)
        raise 'expected relation to be present' unless relation

        sql_column ||= sql_column(name)
        sql_type = (as || sql_type(name))

        association = associated(name)
        sql_direction = sql_direction(direction)
        @relation = relation.reorder(nil) if reorder

        case sql_type
        when :belongs_to
          relation
            .order(Arel.sql("#{is_null(sql_column)} ASC"))
            .order(order_by_associated_conditions(association, sort: sort, direction: direction, limit: limit))
        when :belongs_to_polymorphic
          relation
            .order(Arel.sql("#{sql_column}_type #{sql_direction}"))
            .order(Arel.sql("#{sql_column}_id #{sql_direction}"))
        when :has_and_belongs_to_many, :has_many, :has_one
          relation
            .order(order_by_associated_conditions(association, sort: sort, direction: direction, limit: limit))
            .order(Arel.sql("#{sql_column(klass.primary_key)} #{sql_direction}"))
        when :effective_addresses
          relation
            .order(order_by_associated_conditions(associated(:addresses), sort: sort, direction: direction, limit: limit))
            .order(Arel.sql("#{sql_column(klass.primary_key)} #{sql_direction}"))
        when :effective_roles
          relation.order(Arel.sql("#{sql_column(:roles_mask)} #{sql_direction}"))
        when :string, :text
          relation
            .order(Arel.sql(("ISNULL(#{sql_column}), " if mysql?).to_s + "#{sql_column}='' ASC, #{sql_column} #{sql_direction}" + (" NULLS LAST" if postgres?).to_s))
          when :time
            relation
              .order(Arel.sql(("ISNULL(#{sql_column}), " if mysql?).to_s + "EXTRACT(hour from #{sql_column}) #{sql_direction}, EXTRACT(minute from #{sql_column}) #{sql_direction}" + (" NULLS LAST" if postgres?).to_s))
        else
          relation
            .order(Arel.sql(("ISNULL(#{sql_column}), " if mysql?).to_s + "#{sql_column} #{sql_direction}" + (" NULLS LAST" if postgres?).to_s))
        end
      end

      def search(name, value, as: nil, fuzzy: true, sql_column: nil)
        raise 'expected relation to be present' unless relation

        sql_column ||= sql_column(name)
        sql_type = (as || sql_type(name))
        fuzzy = true unless fuzzy == false

        if ['SUM(', 'COUNT(', 'MAX(', 'MIN(', 'AVG('].any? { |str| sql_column.to_s.include?(str) }
          return relation.having("#{sql_column} = ?", value)
        end

        association = associated(name)

        term = Effective::Attribute.new(sql_type, klass: (association.try(:klass) rescue nil) || klass).parse(value, name: name)

        # term == 'nil' rescue false is a Rails 4.1 fix, where you can't compare a TimeWithZone to 'nil'
        if (term == 'nil' rescue false) && ![:has_and_belongs_to_many, :has_many, :has_one, :belongs_to_polymorphic, :effective_roles].include?(sql_type)
          return relation.where(is_null(sql_column))
        end

        case sql_type
        when :belongs_to, :has_and_belongs_to_many, :has_many, :has_one
          relation.where(search_by_associated_conditions(association, term, fuzzy: fuzzy))
        when :belongs_to_polymorphic
          (type, id) = term.split('_')

          if type.present? && id.present?
            relation.where("#{sql_column}_id = ?", id).where("#{sql_column}_type = ?", type)
          else
            id ||= Effective::Attribute.new(:integer).parse(term)
            relation.where("#{sql_column}_id = ? OR #{sql_column}_type = ?", id, (type || term))
          end
        when :effective_addresses
          relation.where(id: Effective::Resource.new(association).search_any(value, fuzzy: fuzzy).pluck(:addressable_id))
        when :effective_obfuscation
          # If value == term, it's an invalid deobfuscated id
          relation.where("#{sql_column} = ?", (value == term ? 0 : term))
        when :effective_roles
          relation.with_role(term)
        when :boolean
          relation.where("#{sql_column} = ?", term)
        when :datetime, :date
          end_at = (
            case (value.to_s.scan(/(\d+)/).flatten).length
            when 1 ; term.end_of_year     # Year
            when 2 ; term.end_of_month    # Year-Month
            when 3 ; term.end_of_day      # Year-Month-Day
            when 4 ; term.end_of_hour     # Year-Month-Day Hour
            when 5 ; term.end_of_minute   # Year-Month-Day Hour-Minute
            when 6 ; term + 1.second      # Year-Month-Day Hour-Minute-Second
            else term
            end
          )
          relation.where("#{sql_column} >= ? AND #{sql_column} <= ?", term, end_at)
        when :time
          timed = relation.where("EXTRACT(hour from #{sql_column}) = ?", term.utc.hour)
          timed = timed.where("EXTRACT(minute from #{sql_column}) = ?", term.utc.min) if term.min > 0
          timed
        when :decimal, :currency
          if fuzzy && (term.round(0) == term) && value.to_s.include?('.') == false
            if term < 0
              relation.where("#{sql_column} <= ? AND #{sql_column} > ?", term, term-1.0)
            else
              relation.where("#{sql_column} >= ? AND #{sql_column} < ?", term, term+1.0)
            end
          else
            relation.where("#{sql_column} = ?", term)
          end
        when :duration
          if fuzzy && (term % 60 == 0) && value.to_s.include?('m') == false
            if term < 0
              relation.where("#{sql_column} <= ? AND #{sql_column} > ?", term, term-60)
            else
              relation.where("#{sql_column} >= ? AND #{sql_column} < ?", term, term+60)
            end
          else
            relation.where("#{sql_column} = ?", term)
          end
        when :integer
          relation.where("#{sql_column} = ?", term)
        when :percentage
          relation.where("#{sql_column} = ?", sql_type(name) == :integer ? (term * 100).to_i : term)
        when :price
          relation.where("#{sql_column} = ?", term)
        when :string, :text, :email
          if fuzzy
            relation.where("#{sql_column} #{ilike} ?", "%#{term}%")
          else
            relation.where("#{sql_column} = ?", term)
          end
        else
          raise "unsupported sql type #{sql_type}"
        end
      end

      def search_any(value, columns: nil, fuzzy: nil)
        raise 'expected relation to be present' unless relation

        # Assume this is a set of IDs
        if value.kind_of?(Integer) || value.kind_of?(Array) || (value.to_i.to_s == value)
          return relation.where(klass.primary_key => value)
        end

        # Otherwise, we fall back to a string/text search of all columns
        columns = Array(columns || search_columns)
        fuzzy = true unless fuzzy == false

        conditions = (
          if fuzzy
            columns.map { |name| "#{sql_column(name)} #{ilike} :fuzzy" }
          else
            columns.map { |name| "#{sql_column(name)} = :value" }
          end
        ).join(' OR ')

        relation.where(conditions, fuzzy: "%#{value}%", value: value)
      end

      private

      def search_by_associated_conditions(association, value, fuzzy: nil)
        resource = Effective::Resource.new(association)

        # Search the target model for its matching records / keys
        relation = resource.search_any(value, fuzzy: fuzzy)

        if association.options[:as] # polymorphic
          relation = relation.where(association.type => klass.name)
        end

        # key: the id, or associated_id on my table
        # keys: the ids themselves as per the target table

        if association.macro == :belongs_to
          key = sql_column(association.foreign_key)
          keys = relation.pluck(association.klass.primary_key)
        elsif association.macro == :has_and_belongs_to_many
          key = sql_column(klass.primary_key)
          values = relation.pluck(association.source_reflection.klass.primary_key).uniq.compact

          keys = klass.joins(association.name)
            .where(association.name => { association.source_reflection.klass.primary_key => values })
            .pluck(klass.primary_key)
        elsif association.options[:through].present?
          key = sql_column(klass.primary_key)

          if association.source_reflection.options[:polymorphic]
            reflected_klass = association.klass
          else
            reflected_klass = association.source_reflection.klass
          end

          values = relation.pluck(reflected_klass.primary_key).uniq.compact

          scope = association.through_reflection.klass.where(association.source_reflection.foreign_key => values)

          if association.source_reflection.options[:polymorphic]
            scope = scope.where(association.source_reflection.foreign_type => reflected_klass.name)
          end

          if association.through_reflection.macro == :belongs_to
            key = association.through_reflection.foreign_key
            keys = scope.pluck(association.through_reflection.klass.primary_key)
          else
            keys = scope.pluck(association.through_reflection.foreign_key)
          end
        elsif association.macro == :has_many
          key = sql_column(klass.primary_key)
          keys = relation.pluck(association.foreign_key)
        elsif association.macro == :has_one
          key = sql_column(klass.primary_key)
          keys = relation.pluck(association.foreign_key)
        end

        "#{key} IN (#{(keys.uniq.compact.presence || [0]).join(',')})"
      end

      def order_by_associated_conditions(association, sort: nil, direction: :asc, limit: nil)
        resource = Effective::Resource.new(association)

        # Order the target model for its matching records / keys
        sort_column = (sort unless sort == true) || resource.sort_column

        relation = resource.order(sort_column, direction, limit: limit, reorder: true).limit([limit, 1000].compact.min)

        if association.options[:as] # polymorphic
          relation = relation.where(association.type => klass.name)
        end

        # key: the id, or associated_id on my table
        # keys: the ids themselves as per the target table

        if association.macro == :belongs_to
          key = sql_column(association.foreign_key)
          keys = relation.pluck(association.klass.primary_key)
        elsif association.macro == :has_and_belongs_to_many
          key = sql_column(klass.primary_key)

          source = "#{association.join_table}.#{association.source_reflection.association_foreign_key}"
          values = relation.pluck(association.source_reflection.klass.primary_key).uniq.compact # The searched keys

          keys = klass.joins(association.name)
            .order(values.uniq.compact.map { |value| "#{source}=#{value} DESC" }.join(','))
            .pluck(klass.primary_key)
        elsif association.macro == :has_many && association.options[:through].present?
          key = sql_column(klass.primary_key)

          source = association.source_reflection.foreign_key
          values = relation.pluck(association.source_reflection.klass.primary_key).uniq.compact # The searched keys

          keys = association.through_reflection.klass
            .order(values.uniq.compact.map { |value| "#{source}=#{value} DESC" }.join(','))
            .pluck(association.through_reflection.foreign_key)
        elsif association.macro == :has_many
          key = sql_column(klass.primary_key)
          keys = relation.pluck(association.foreign_key)
        elsif association.macro == :has_one
          key = sql_column(klass.primary_key)
          keys = relation.pluck(association.foreign_key)
        end

        keys.uniq.compact.map { |value| "#{key}=#{value} DESC" }.join(',')
      end

    end
  end
end
