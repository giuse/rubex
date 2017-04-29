module Rubex
  module AST
    module TopStatement
      class CBindings
        attr_reader :lib, :declarations

        def initialize lib, declarations
          @lib, @declarations = lib, declarations
        end

        def analyse_statements local_scope
          @declarations.each do |stat|
            stat.analyse_statement local_scope, extern: true
          end
          local_scope.include_files.push @lib
        end

        def generate_code code

        end

        class CFunctionDecl
          include Rubex::AST::Statement
          attr_reader :type, :name, :args, :extern

          def initialize type, name, args
            @type, @name, @args = type, name, args
          end

          def analyse_statement local_scope, extern: false
            @extern = extern
            @args.map! do |a|
              determine_dtype a
            end
            c_name = @extern ? name : Rubex::C_FUNC_PREFIX + name
            type = determine_dtype @type
            @type = Rubex::DataType::CMethod.new(@name, c_name, @args, type, nil)
            local_scope.add_c_method(name: @name, c_name: c_name, 
              extern: @extern,)
          end

        private

          def determine_dtype dtype_or_ptr
            if dtype_or_ptr[-1] == "*"
              Rubex::DataType::CPtr.new simple_dtype(dtype_or_ptr[0...-1])
            else
              simple_dtype(dtype_or_ptr)
            end
          end

          def simple_dtype dtype
            Rubex::CUSTOM_TYPES[dtype] || Rubex::TYPE_MAPPINGS[dtype].new
          end
        end # class CFunctionDecl
      end # class CBindings

      class MethodDef
        # Ruby name of the method.
        attr_reader :name
        # Method arguments.
        attr_reader :arg_list
        # The statments/expressions contained within the method.
        attr_reader :statements
        # Symbol Table entry.
        attr_reader :entry
        # Instance of Scope::Local for this method.
        attr_reader :scope

        def initialize name, arg_list, statements
          @name, @arg_list, @statements = name, arg_list, statements
        end

        def analyse_statements outer_scope
          @scope = Rubex::SymbolTable::Scope::Local.new
          @entry = outer_scope.find @name
          @entry.type.scope = @scope
          @entry.type.arg_list = @arg_list
          @scope.outer_scope = outer_scope
          @scope.type = @entry.type
          @scope.self_name = Rubex::ARG_PREFIX + "self"
          @arg_list.each do |arg|
            arg.analyse_statement @scope
            @scope.add_arg(name: arg.name, c_name: Rubex::ARG_PREFIX + arg.name,
              type: arg.type, value: arg.value)
          end

          @statements.each do |stat|
            stat.analyse_statement @scope
          end
        end

        # Option c_function - When set to true, certain code that is not required
        #   for Ruby methods will be generated too.
        def generate_code code, c_method: false
          code.block do
            generate_function_definition code, c_method: c_method
          end
        end

        def rescan_declarations scope
          @statements.each do |stat|
            stat.respond_to?(:rescan_declarations) and
            stat.rescan_declarations(@scope)
          end
        end

      private
        def generate_function_definition code, c_method:
          declare_types code
          declare_args code unless c_method
          declare_vars code, @scope
          declare_carrays code, @scope
          declare_ruby_objects code, @scope
          generate_arg_checking code unless c_method
          init_args code unless c_method
          init_vars code
          declare_carrays_using_init_var_value code
          generate_statements code
        end


        def declare_types code
          @scope.type_entries.each do |entry|
            type = entry.type

            if type.alias_type?
              code << "typedef #{type.old_name} #{type.new_name};"
            elsif type.struct_or_union?
              code << sue_header(entry)
              code.block(sue_footer(entry)) do
                declare_vars code, type.scope
                declare_carrays code, type.scope
                declare_ruby_objects code, type.scope
              end
            end
            code.nl
          end
        end

        def sue_header entry
          type = entry.type
          str = "#{type.kind} #{type.name}"
          if !entry.extern
            str.prepend "typedef "
          end

          str
        end

        def sue_footer entry
          str =
          if entry.extern
            ";"
          else
            " #{entry.type.c_name};"
          end

          str
        end

        def declare_ruby_objects code, scope
          scope.ruby_obj_entries.each do |var|
            code.declare_variable type: var.type.to_s, c_name: var.c_name
          end
        end

        def generate_statements code
          @statements.each do |stat|
            stat.generate_code code, @scope
          end
        end

        def declare_args code
          @scope.arg_entries.each do |arg|
            code.declare_variable type: arg.type.to_s, c_name: arg.c_name
          end
        end

        def declare_vars code, scope
          scope.var_entries.each do |var|
            code.declare_variable type: var.type.to_s, c_name: var.c_name
          end
        end

        def declare_carrays code, scope
          scope.carray_entries.select { |s|
            s.type.dimension.is_a? Rubex::AST::Expression::Literal
          }. each do |arr|
            type = arr.type.type.to_s
            c_name = arr.c_name
            dimension = arr.type.dimension.c_code(@scope)
            value = arr.value.map { |a| a.c_code(@scope) } if arr.value
            code.declare_carray(type: type, c_name: c_name, dimension: dimension,
              value: value)
          end
        end

        def init_args code
          @scope.arg_entries.each_with_index do |arg, i|
            code << arg.c_name + '=' + arg.type.from_ruby_object("argv[#{i}]")
            code << ";"
            code.nl
          end
        end

        def init_vars code
          @scope.var_entries.select { |v| v.value }.each do |var|
            init_variable code, var
          end
        end

        def init_variable code, var
          rhs = var.value.c_code(@scope)
          if var.value.type.object?
            rhs = "#{var.type.from_ruby_object(rhs)}"
          end
          rhs = "(#{var.type.to_s})(#{rhs})"
          lhs = var.c_name

          code.init_variable lhs: lhs, rhs: rhs
        end

        def declare_carrays_using_init_var_value code
          @scope.carray_entries.select { |s|
            !s.type.dimension.is_a?(Rubex::AST::Expression::Literal)
          }. each do |arr|
            type = arr.type.type.to_s
            c_name = arr.c_name
            dimension = arr.type.dimension.c_code(@scope)
            value = arr.value.map { |a| a.c_code(@scope) } if arr.value
            code.declare_carray(type: type, c_name: c_name, dimension: dimension,
              value: value)
          end
        end

        def generate_arg_checking code
          code << 'if (argc != ' + @scope.arg_entries.size.to_s + ")"
          code.block do
            code << %Q{rb_raise(rb_eArgError, "Need #{@scope.arg_entries.size} args, not %d", argc);\n}
          end
        end
      end

      class RubyMethodDef < MethodDef
        def generate_code code
          code.write_ruby_method_header(type: @entry.type.type.to_s,
            c_name: @entry.c_name)
          super
        end

        def == other
          self.class == other.class && @name == other.name &&
          @c_name == other.c_name && @arg_list == other.arg_list &&
          @statements == other.statements && @entry == other.entry &&
          @type == other.type
        end
      end # class RubyMethodDef

      class CMethodDef < MethodDef
        attr_reader :type

        def initialize type, name, arg_list, statements
          super(name, arg_list, statements)
          @type = type
          # self is a compulsory implicit argument for C methods.
          @arg_list << CBaseType.new('object', 'self', nil)
        end

        def analyse_statements outer_scope, extern: false
          super(outer_scope)
        end

        def generate_code code
          code.write_c_method_header(type: @entry.type.type.to_s, 
            c_name: @entry.c_name, args: Helpers.create_arg_arrays(@scope))
          super code, c_method: true
        end
      end # class CMethodDef

      class Klass
        # Stores the scope of the class. Rubex::SymbolTable::Scope::Klass.
        attr_reader :scope

        attr_reader :name

        attr_reader :ancestor

        attr_reader :statements

        attr_reader :entry

        # Name of the class. Ancestor can be Scope::Klass or String object 
        #   depending on whether invoker is another higher level scope or
        #   the parser. Statements are the statements inside the class.
        def initialize name, ancestor, statements
          @name, @ancestor, @statements = name, ancestor, statements
          @ancestor = 'Object' if @ancestor.nil?
        end

        def analyse_statements local_scope
          @entry = local_scope.find(@name)
          @scope = @entry.type.scope
          @ancestor = @entry.type.ancestor
          add_statement_symbols_to_symbol_table
          @statements.each do |stat|
            stat.analyse_statements @scope
          end
        end

        def rescan_declarations local_scope
          @statements.each do |stat|
            stat&.rescan_declarations(@scope)
          end
        end

        def generate_code code
          @statements.each do |stat|
            stat.generate_code code
          end
        end

      private

        def add_statement_symbols_to_symbol_table
          @statements.each do |stat|
            name = stat.name
            if stat.is_a? Rubex::AST::TopStatement::RubyMethodDef
              c_name = Rubex::RUBY_FUNC_PREFIX + @name + "_" +
                name.gsub("?", "_qmark").gsub("!", "_bang")
              @scope.add_ruby_method name: name, c_name: c_name
            elsif stat.is_a? Rubex::AST::TopStatement::CMethodDef
              c_name = Rubex::C_FUNC_PREFIX + @name + "_" + name
              type = Rubex::DataType::CMethod.new(
                name, c_name, stat.arg_list, determine_dtype(stat.type))
              @scope.add_c_method(name: name, c_name: c_name, extern: false,
                type: type)
            end
          end
        end

        def determine_dtype dtype_or_ptr
          if dtype_or_ptr[-1] == "*"
            Rubex::DataType::CPtr.new simple_dtype(dtype_or_ptr[0...-1])
          else
            simple_dtype(dtype_or_ptr)
          end
        end

        def simple_dtype dtype
          Rubex::CUSTOM_TYPES[dtype] || Rubex::TYPE_MAPPINGS[dtype].new
        end
      end # class Klass
    end # module TopStatement
  end # module AST
end # module Rubex