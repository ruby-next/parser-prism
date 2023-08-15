# frozen_string_literal: true

require "parser"
require "yarp"

module Parser
  module YARP
    class Visitor < ::YARP::BasicVisitor
      attr_reader :buffer, :context

      def initialize(buffer)
        @buffer = buffer
        @context = { destructure: false, locals: [], pattern: false }
      end

      def visit_alias_node(node)
        s(:alias, [visit(node.new_name), visit(node.old_name)])
      end

      def visit_alternation_pattern_node(node)
        s(:match_alt, [visit(node.left), visit(node.right)])
      end

      def visit_and_node(node)
        s(:and, [visit(node.left), visit(node.right)])
      end

      def visit_array_node(node)
        s(:array, visit_all(node.elements))
      end

      def visit_array_pattern_node(node)
        s(:array_pattern, visit_all(node.requireds))
      end

      def visit_arguments_node(node)
        case node.arguments.length
        when 0
          raise
        when 1
          [visit(node.arguments.first)]
        else
          visit_all(node.arguments)
        end
      end

      def visit_assoc_node(node)
        if context[:pattern] && node.value.nil?
          s(:match_var, [node.key.unescaped.to_sym])
        elsif node.value.nil?
          name = node.key.unescaped.to_sym
          type = name[0].match?(/[[:upper:]]/) ? :const : :send

          s(:pair, [visit(node.key), s(type, [nil, name])])
        else
          s(:pair, [visit(node.key), visit(node.value)])
        end
      end

      def visit_assoc_splat_node(node)
        if node.value.nil? && context[:locals].include?(:**)
          s(:forwarded_kwrestarg)
        else
          s(:kwsplat, [visit(node.value)])
        end
      end

      def visit_back_reference_read_node(node)
        s(:back_ref, [node.slice.to_sym])
      end

      def visit_begin_node(node)
        if node.rescue_clause.nil? && node.ensure_clause.nil? && node.else_clause.nil?
          if node.statements.nil?
            s(:kwbegin)
          else
            child = visit(node.statements)
            child.type == :begin ? s(:kwbegin, child.children) : s(:kwbegin, [child])
          end
        else
          result = visit(node.statements)

          if node.rescue_clause
            rescue_node = visit(node.rescue_clause)
            children = [result] + rescue_node.children

            if node.else_clause
              children.pop
              children << visit(node.else_clause)
            end

            result = s(rescue_node.type, children)
          end

          if node.ensure_clause
            ensure_node = visit(node.ensure_clause)
            result = s(ensure_node.type, [result] + ensure_node.children)
          end

          if node.begin_keyword_loc
            s(:kwbegin, [result])
          else
            result
          end
        end
      end

      def visit_block_argument_node(node)
        s(:block_pass, [visit(node.expression)])
      end

      def visit_block_node(node)
        [node.parameters.nil? ? s(:args) : s(:args, visit(node.parameters)), visit(node.statements)]
      end

      def visit_block_parameter_node(node)
        s(:blockarg, [node.name&.to_sym])
      end

      def visit_block_parameters_node(node)
        [*visit(node.parameters), *node.locals.map { |local| s(:shadowarg, [local.slice.to_sym]) }]
      end

      def visit_break_node(node)
        s(:break, visit(node.arguments))
      end

      def visit_call_node(node)
        if node.message == "=~" && node.receiver.is_a?(::YARP::RegularExpressionNode) && node.arguments && node.arguments.arguments.length == 1
          return s(:match_with_lvasgn, [visit(node.receiver), visit(node.arguments.arguments.first)])
        elsif node.message == "-" && [::YARP::IntegerNode, ::YARP::FloatNode, ::YARP::RationalNode, ::YARP::ImaginaryNode].include?(node.receiver.class) && node.arguments.nil?
          result = visit(node.receiver)
          return s(result.type, [-result.children.first])
        end

        type = node.safe_navigation? ? :csend : :send
        parts = [visit(node.receiver), node.name.to_sym]
        parts.concat(visit(node.arguments)) unless node.arguments.nil?

        if node.block
          s(:block, [s(type, parts)].concat(visit(node.block)))
        else
          s(type, parts)
        end
      end

      def visit_call_operator_and_write_node(node)
        s(:and_asgn, [visit_operator_target(node.target), visit(node.value)])
      end

      def visit_call_operator_or_write_node(node)
        s(:or_asgn, [visit_operator_target(node.target), visit(node.value)])
      end

      def visit_call_operator_write_node(node)
        s(:op_asgn, [visit_operator_target(node.target), node.operator.chomp("=").to_sym, visit(node.value)])
      end

      def visit_case_node(node)
        if node.conditions.first.is_a?(::YARP::WhenNode)
          s(:case, [visit(node.predicate), *visit_all(node.conditions), visit(node.consequent)])
        else
          consequent = node.consequent && node.consequent.statements.nil? ? s(:empty_else) : visit(node.consequent)
          s(:case_match, [visit(node.predicate), *visit_all(node.conditions), consequent])
        end
      end

      def visit_class_node(node)
        s(:class, [visit(node.constant_path), visit(node.superclass), with_context(:locals, node.locals) { visit(node.statements) }])
      end

      def visit_class_variable_operator_and_write_node(node)
        s(:and_asgn, [s(:cvasgn, [node.name.to_sym]), visit(node.value)])
      end

      def visit_class_variable_operator_or_write_node(node)
        s(:or_asgn, [s(:cvasgn, [node.name.to_sym]), visit(node.value)])
      end

      def visit_class_variable_operator_write_node(node)
        s(:op_asgn, [s(:cvasgn, [node.name.to_sym]), node.operator, visit(node.value)])
      end

      def visit_class_variable_read_node(node)
        s(:cvar, [node.slice.to_sym])
      end

      def visit_class_variable_write_node(node)
        s(:cvasgn, [node.name.to_sym, visit(node.value)])
      end

      def visit_constant_operator_and_write_node(node)
        s(:and_asgn, [s(:casgn, [nil, node.name.to_sym]), visit(node.value)])
      end

      def visit_constant_operator_or_write_node(node)
        s(:or_asgn, [s(:casgn, [nil, node.name.to_sym]), visit(node.value)])
      end

      def visit_constant_operator_write_node(node)
        s(:op_asgn, [s(:casgn, [nil, node.name.to_sym]), node.operator, visit(node.value)])
      end

      def visit_constant_path_node(node)
        value = node.child.is_a?(::YARP::ConstantReadNode) ? node.child.slice.to_sym : visit(node.child)
        s(:const, [node.parent ? visit(node.parent) : s(:cbase), value])
      end

      def visit_constant_path_operator_and_write_node(node)
        s(:and_asgn, [s(:casgn, visit(node.target).children), visit(node.value)])
      end

      def visit_constant_path_operator_or_write_node(node)
        s(:or_asgn, [s(:casgn, visit(node.target).children), visit(node.value)])
      end

      def visit_constant_path_operator_write_node(node)
        s(:op_asgn, [s(:casgn, visit(node.target).children), node.operator, visit(node.value)])
      end

      def visit_constant_path_write_node(node)
        if node.value.nil?
          s(:casgn, visit(node.target).children)
        else
          s(:casgn, [*visit(node.target).children, visit(node.value)])
        end
      end

      def visit_constant_read_node(node)
        s(:const, [nil, node.slice.to_sym])
      end

      def visit_constant_write_node(node)
        s(:casgn, [nil, node.name.to_sym, visit(node.value)])
      end

      def visit_def_node(node)
        parts = [
          node.name.to_sym,
          if node.parameters.nil?
            s(:args)
          elsif node.parameters.requireds.empty? &&
                node.parameters.optionals.empty? &&
                node.parameters.rest.nil? &&
                node.parameters.posts.empty? &&
                node.parameters.keywords.empty? &&
                node.parameters.keyword_rest.is_a?(::YARP::ForwardingParameterNode) &&
                node.parameters.block.nil?
            s(:forward_args)
          else
            s(:args, visit(node.parameters))
          end,
          with_context(:locals, node.locals) { visit(node.statements) }
        ]

        if node.receiver.is_a?(::YARP::ParenthesesNode)
          s(:defs, [visit(node.receiver.statements), *parts])
        elsif !node.receiver.nil?
          s(:defs, [visit(node.receiver), *parts])
        else
          s(:def, parts)
        end
      end

      def visit_defined_node(node)
        s(:defined?, [visit(node.value)])
      end

      def visit_else_node(node)
        visit(node.statements)
      end

      def visit_embedded_statements_node(node)
        s(:begin, node.statements ? [visit(node.statements)] : [])
      end

      def visit_embedded_variable_node(node)
        visit(node.variable)
      end

      def visit_ensure_node(node)
        s(:ensure, [visit(node.statements)])
      end

      def visit_false_node(node)
        s(:false)
      end

      def visit_flip_flop_node(node)
        s(node.exclude_end? ? :eflipflop : :iflipflop, [visit(node.left), visit(node.right)])
      end

      def visit_float_node(node)
        s(:float, [node.slice.to_f])
      end

      def visit_for_node(node)
        s(:for, [visit(node.index), visit(node.collection), visit(node.statements)])
      end

      def visit_forwarding_arguments_node(node)
        s(:forwarded_args)
      end

      def visit_forwarding_parameter_node(node)
        s(:forward_arg)
      end

      def visit_forwarding_super_node(node)
        if node.block
          s(:block, [s(:zsuper)].concat(visit(node.block)))
        else
          s(:zsuper)
        end
      end

      def visit_global_variable_operator_and_write_node(node)
        s(:and_asgn, [s(:gvasgn, [node.name.to_sym]), visit(node.value)])
      end

      def visit_global_variable_operator_or_write_node(node)
        s(:or_asgn, [s(:gvasgn, [node.name.to_sym]), visit(node.value)])
      end

      def visit_global_variable_operator_write_node(node)
        s(:op_asgn, [s(:gvasgn, [node.name.to_sym]), node.operator, visit(node.value)])
      end

      def visit_global_variable_read_node(node)
        s(:gvar, [node.slice.to_sym])
      end

      def visit_global_variable_write_node(node)
        s(:gvasgn, [node.name.to_sym, visit(node.value)])
      end

      def visit_hash_node(node)
        s(:hash, visit_all(node.elements))
      end

      def visit_hash_pattern_node(node)
        s(:hash_pattern, visit_all(node.assocs))
      end

      def visit_if_node(node)
        s(:if, [visit(node.predicate), visit(node.statements), visit(node.consequent)])
      end

      def visit_imaginary_node(node)
        s(:complex, [eval(node.slice)])
      end

      def visit_in_node(node)
        s(:in_pattern, [with_context(:pattern, true) { visit(node.pattern) }, nil, visit(node.statements)])
      end

      def visit_instance_variable_operator_and_write_node(node)
        s(:and_asgn, [s(:ivasgn, [node.name.to_sym]), visit(node.value)])
      end

      def visit_instance_variable_operator_or_write_node(node)
        s(:or_asgn, [s(:ivasgn, [node.name.to_sym]), visit(node.value)])
      end

      def visit_instance_variable_operator_write_node(node)
        s(:op_asgn, [s(:ivasgn, [node.name.to_sym]), node.operator, visit(node.value)])
      end

      def visit_instance_variable_read_node(node)
        s(:ivar, [node.slice.to_sym])
      end

      def visit_instance_variable_write_node(node)
        if node.value
          s(:ivasgn, [node.name.to_sym, visit(node.value)])
        else
          s(:ivasgn, [node.name.to_sym])
        end
      end

      def visit_integer_node(node)
        s(:int, [node.slice.to_i])
      end

      def visit_interpolated_regular_expression_node(node)
        s(:regexp, visit_all(node.parts).push(s(:regopt, node.closing[1..].chars.map(&:to_sym))))
      end

      def visit_interpolated_string_node(node)
        if node.opening&.start_with?("<<")
          visit_heredoc(:dstr, node.parts)
        elsif node.parts.length == 1 && node.parts.first.is_a?(::YARP::StringNode)
          visit(node.parts.first)
        else
          s(:dstr, visit_all(node.parts))
        end
      end

      def visit_interpolated_symbol_node(node)
        s(:dsym, visit_all(node.parts))
      end

      def visit_interpolated_x_string_node(node)
        if node.opening.start_with?("<<")
          visit_heredoc(:xstr, node.parts)
        else
          s(:xstr, visit_all(node.parts))
        end
      end

      alias visit_keyword_hash_node visit_hash_node

      def visit_keyword_parameter_node(node)
        if node.value
          s(:kwoptarg, [node.name.chomp(":").to_sym, visit(node.value)])
        else
          s(:kwarg, [node.name.chomp(":").to_sym])
        end
      end

      def visit_keyword_rest_parameter_node(node)
        if node.name
          s(:kwrestarg, [node.name.to_sym])
        else
          s(:kwrestarg)
        end
      end

      def visit_lambda_node(node)
        s(:block, [s(:send, [nil, :lambda]), node.parameters ? s(:args, visit(node.parameters)) : s(:args), with_context(:locals, node.locals) { visit(node.statements) }])
      end

      def visit_local_variable_operator_and_write_node(node)
        s(:and_asgn, [s(:lvasgn, [node.constant_id]), visit(node.value)])
      end

      def visit_local_variable_operator_or_write_node(node)
        s(:or_asgn, [s(:lvasgn, [node.constant_id]), visit(node.value)])
      end

      def visit_local_variable_operator_write_node(node)
        s(:op_asgn, [s(:lvasgn, [node.constant_id]), node.operator_id, visit(node.value)])
      end

      def visit_local_variable_read_node(node)
        s(:lvar, [node.constant_id])
      end

      def visit_local_variable_write_node(node)
        parts = [node.constant_id]
        parts << visit(node.value) if node.value
        s(context[:pattern] ? :match_var : :lvasgn, parts)
      end

      def visit_match_predicate_node(node)
        s(:match_pattern_p, [visit(node.value), with_context(:pattern, true) { visit(node.pattern) }])
      end

      def visit_match_required_node(node)
        s(:match_pattern, [visit(node.value), with_context(:pattern, true) { visit(node.pattern) }])
      end

      def visit_module_node(node)
        s(:module, [visit(node.constant_path), with_context(:locals, node.locals) { visit(node.statements) }])
      end

      def visit_multi_write_node(node)
        if node.targets.length == 1 && node.value.nil?
          visit(node.targets.first)
        elsif node.value.nil?
          s(:mlhs, visit_all(node.targets))
        else
          s(:masgn, [s(:mlhs, visit_all(node.targets)), visit(node.value)])
        end
      end

      def visit_next_node(node)
        s(:next, visit(node.arguments))
      end

      def visit_nil_node(node)
        s(:nil)
      end

      def visit_no_keywords_parameter_node(node)
        s(:kwnilarg)
      end

      def visit_numbered_reference_read_node(node)
        s(:nth_ref, [node.slice.delete_prefix("$").to_i])
      end

      def visit_optional_parameter_node(node)
        s(:optarg, [node.constant_id, visit(node.value)])
      end

      def visit_or_node(node)
        s(:or, [visit(node.left), visit(node.right)])
      end

      def visit_parameters_node(node)
        params = []
        params.concat(visit_all(node.requireds)) if node.requireds.any?
        params.concat(visit_all(node.optionals)) if node.optionals.any?
        params << visit(node.rest) if !node.rest.nil? && node.rest.operator != ","
        params.concat(visit_all(node.posts)) if node.posts.any?
        params.concat(visit_all(node.keywords)) if node.keywords.any?
        params << visit(node.keyword_rest) if !node.keyword_rest.nil?
        params << visit(node.block) if !node.block.nil?
        params
      end

      def visit_parentheses_node(node)
        if node.statements.nil?
          s(:begin)
        else
          child = visit(node.statements)
          child.type == :begin ? child : s(:begin, [child])
        end
      end

      def visit_post_execution_node(node)
        s(:postexe, [visit(node.statements)])
      end

      def visit_pre_execution_node(node)
        s(:preexe, [visit(node.statements)])
      end

      def visit_program_node(node)
        visit(node.statements)
      end

      def visit_range_node(node)
        s(node.exclude_end? ? :erange : :irange, [visit(node.left), visit(node.right)])
      end

      def visit_rational_node(node)
        s(:rational, [node.slice.to_r])
      end

      def visit_redo_node(node)
        s(:redo)
      end

      def visit_regular_expression_node(node)
        s(:regexp, [s(:str, [node.content]), s(:regopt, node.closing[1..].chars.map(&:to_sym))])
      end

      def visit_required_destructured_parameter_node(node)
        s(:mlhs, with_context(:destructured, true) { visit_all(node.parameters) })
      end

      def visit_required_parameter_node(node)
        s(:arg, [node.constant_id])
      end

      def visit_rescue_modifier_node(node)
        s(:rescue, [visit(node.expression), s(:resbody, [nil, nil, visit(node.rescue_expression)]), nil])
      end

      def visit_rescue_node(node)
        resbody_children = [
          node.exceptions.any? ? s(:array, visit_all(node.exceptions)) : nil,
          node.reference ? visit(node.reference) : nil,
          visit(node.statements)
        ]

        children = [s(:resbody, resbody_children)]
        if node.consequent
          children.concat(visit(node.consequent).children)
        else
          children << nil
        end

        s(:rescue, children)
      end

      def visit_rest_parameter_node(node)
        if node.name
          s(:restarg, [node.name.to_sym])
        else
          s(:restarg)
        end
      end

      def visit_retry_node(node)
        s(:retry)
      end

      def visit_return_node(node)
        s(:return, visit(node.arguments))
      end

      def visit_self_node(node)
        s(:self)
      end

      def visit_singleton_class_node(node)
        s(:sclass, [visit(node.expression), with_context(:locals, node.locals) { visit(node.statements) }])
      end

      def visit_source_encoding_node(node)
        s(:const, [s(:const, [nil, :Encoding], nil), :UTF_8])
      end

      def visit_source_file_node(node)
        s(:str, [buffer.name])
      end

      def visit_source_line_node(node)
        s(:int, [node.location.start_line])
      end

      def visit_splat_node(node)
        if node.expression.nil? && context[:locals].include?(:*)
          s(:forwarded_restarg)
        elsif context[:destructured]
          s(:restarg, node.expression.nil? ? [] : [node.expression.constant_id])
        else
          s(:splat, [visit(node.expression)])
        end
      end

      def visit_statements_node(node)
        case node.body.length
        when 0
          # nothing
        when 1
          visit(node.body.first)
        else
          s(:begin, visit_all(node.body))
        end
      end

      def visit_string_concat_node(node)
        s(:dstr, [visit(node.left), visit(node.right)])
      end

      def visit_string_node(node)
        s(:str, [node.unescaped])
      end

      def visit_super_node(node)
        inner = s(:super, visit(node.arguments))
        node.block ? s(:block, [inner].concat(visit(node.block))) : inner
      end

      def visit_symbol_node(node)
        s(:sym, [node.unescaped.to_sym])
      end

      def visit_true_node(node)
        s(:true)
      end

      def visit_undef_node(node)
        s(:undef, visit_all(node.names))
      end

      def visit_unless_node(node)
        s(:if, [visit(node.predicate), visit(node.consequent), visit(node.statements)])
      end

      def visit_until_node(node)
        s(node.begin_modifier? ? :until_post : :until, [visit(node.predicate), visit(node.statements)])
      end

      def visit_when_node(node)
        s(:when, visit_all(node.conditions).push(visit(node.statements)))
      end

      def visit_while_node(node)
        s(node.begin_modifier? ? :while_post : :while, [visit(node.predicate), visit(node.statements)])
      end

      def visit_x_string_node(node)
        s(:xstr, [s(:str, [node.unescaped])])
      end

      def visit_yield_node(node)
        if node.arguments
          s(:yield, visit(node.arguments))
        else
          s(:yield)
        end
      end

      private

      def s(type, children = [], location = nil)
        AST::Node.new(type, children, location: location)
      end

      def visit_heredoc(type, parts)
        children = []
        parts.each do |part|
          pushing =
            if part.is_a?(::YARP::StringNode) && part.unescaped.count("\n") > 1
              part.unescaped.split("\n").map { |line| s(:str, ["#{line}\n"]) }
            else
              [visit(part)]
            end

          pushing.each do |child|
            if child.type == :str && children.last && children.last.type == :str && !children.last.children.first.end_with?("\n")
              children.last.children.first << child.children.first
            else
              children << child
            end
          end
        end

        if type != :xstr && children.length == 1
          s(children.first.type, children.first.children)
        else
          s(type, children)
        end
      end

      def visit_operator_target(target)
        target = visit(target)

        children = [*target.children]
        children[1] = children[1].name.chomp("=").to_sym

        s(target.type, children)
      end

      def with_context(key, value)
        previous = context[key]
        context[key] = value

        begin
          yield
        ensure
          context[key] = previous
        end
      end
    end

    # Parse the contents of the given buffer and return the AST.
    def self.parse(buffer)
      ::YARP.parse(buffer.source, buffer.name).value.accept(Visitor.new(buffer))
    end
  end
end