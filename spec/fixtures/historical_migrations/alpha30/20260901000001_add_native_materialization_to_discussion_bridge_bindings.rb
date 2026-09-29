# frozen_string_literal: true

class AddNativeMaterializationToDiscussionBridgeBindings < ActiveRecord::Migration[7.0]
  def change
    add_column :discussion_bridge_content_bindings,
               :native_materialization,
               :boolean,
               null: false,
               default: false
  end
end
