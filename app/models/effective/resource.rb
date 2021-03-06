module Effective
  class Resource
    include Effective::Resources::Actions
    include Effective::Resources::Associations
    include Effective::Resources::Attributes
    include Effective::Resources::Init
    include Effective::Resources::Instance
    include Effective::Resources::Forms
    include Effective::Resources::Klass
    include Effective::Resources::Naming
    include Effective::Resources::Paths
    include Effective::Resources::Relation
    include Effective::Resources::Sql

    # post, Post, Admin::Post, admin::Post, admin/posts, admin/post, admin/effective::post
    def initialize(input, namespace: nil)
      _initialize(input, namespace: namespace)
    end

    def to_s
      name
    end

  end
end
