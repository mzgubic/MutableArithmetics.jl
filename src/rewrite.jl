# Heavily inspired from `JuMP/src/parse_expr.jl` code.

export @rewrite
macro rewrite(expr)
    return rewrite_and_return(expr)
end

struct Zero end
# We need to copy `x` as it will be used as might be given by the user and be
# given as first argument of `operate!`.
Base.:(+)(zero::Zero, x) = copy_if_mutable(x)
# `add_mul(zero, ...)` redirects to `muladd(..., zero)` which calls `... + zero`.
Base.:(+)(x, zero::Zero) = copy_if_mutable(x)

using Base.Meta

# See `JuMP._try_parse_idx_set`
function _try_parse_idx_set(arg::Expr)
    # [i=1] and x[i=1] parse as Expr(:vect, Expr(:(=), :i, 1)) and
    # Expr(:ref, :x, Expr(:kw, :i, 1)) respectively.
    if arg.head === :kw || arg.head === :(=)
        @assert length(arg.args) == 2
        return true, arg.args[1], arg.args[2]
    elseif isexpr(arg, :call) && arg.args[1] === :in
        return true, arg.args[2], arg.args[3]
    else
        return false, nothing, nothing
    end
end

function _parse_idx_set(arg::Expr)
    parse_done, idxvar, idxset = _try_parse_idx_set(arg)
    if parse_done
        return idxvar, idxset
    end
    error("Invalid syntax: $arg")
end

"""
    rewrite_generator(expr::Expr, inner::Function)

Rewrites the generator statements `expr` and returns a properly nested for loop
with nested filters as specified.

# Examples

```jldoctest
julia> using MutableArithmetics

julia> MutableArithmetics.rewrite_generator(:(i for i in 1:2 if isodd(i)), i -> :(\$i + 1))
:(for \$(Expr(:escape, :(i = 1:2)))
      if \$(Expr(:escape, :(isodd(i))))
          i + 1
      end
  end)
```
"""
function rewrite_generator(ex, inner)
    # `i + j for i in 1:2 for j in 1:2` is a `flatten` expression
    if isexpr(ex, :flatten)
        return rewrite_generator(ex.args[1], inner)
    end
    if !isexpr(ex, :generator)
        return inner(ex)
    end
    # `i + j for i in 1:2, j in 1:2` is a `generator` expression
    function itrsets(sets)
        if isa(sets, Expr)
            return sets
        elseif length(sets) == 1
            return sets[1]
        else
            return Expr(:block, sets...)
        end
    end

    idxvars = []
    if isexpr(ex.args[2], :filter) # if condition
        loop = Expr(:for, esc(itrsets(ex.args[2].args[2:end])),
                    Expr(:if, esc(ex.args[2].args[1]),
                          rewrite_generator(ex.args[1], inner)))
        for idxset in ex.args[2].args[2:end]
            idxvar, s = _parse_idx_set(idxset)
            push!(idxvars, idxvar)
        end
    else
        loop = Expr(:for, esc(itrsets(ex.args[2:end])),
                         rewrite_generator(ex.args[1], inner))
        for idxset in ex.args[2:end]
            idxvar, s = _parse_idx_set(idxset)
            push!(idxvars, idxvar)
        end
    end
    return loop
end

# See `JuMP._is_sum`
_is_sum(s::Symbol) = (s == :sum) || (s == :∑) || (s == :Σ)

function _parse_generator(x::Expr, aff::Symbol, lcoeffs, rcoeffs, new_var=gensym())
    @assert isexpr(x,:call)
    @assert length(x.args) > 1
    @assert isexpr(x.args[2], :generator) || isexpr(x.args[2], :flatten)
    header = x.args[1]
    if _is_sum(header)
        _parse_generator_sum(x.args[2], aff, lcoeffs, rcoeffs, new_var)
    else
        error("Expected sum outside generator expression; got $header")
    end
end

function _parse_generator_sum(x::Expr, aff::Symbol, lcoeffs, rcoeffs, new_var)
    # We used to preallocate the expression at the lowest level of the loop.
    # When rewriting this some benchmarks revealed that it actually doesn't
    # seem to help anymore, so might as well keep the code simple.
    code = rewrite_generator(x, t -> _rewrite(t, aff, lcoeffs, rcoeffs, aff)[2])
    return :($code; $new_var=$aff)
end

_is_complex_expr(ex) = isa(ex, Expr) && !isexpr(ex, :ref)

function rewrite(x)
    variable = gensym()
    code = rewrite_and_return(x)
    return variable, :($variable = $code)
end
function rewrite_and_return(x)
    variable = gensym()
    output_variable, code = _rewrite_to(x, variable)
    # We need to use `let` because `rewrite(:(sum(i for i in 1:2))`
    return quote
        let
            $variable = MutableArithmetics.Zero()
            $code
            $output_variable
        end
    end
end

_rewrite_to(x, variable::Symbol) = _rewrite(x, variable, [], [])

function _is_comparison(ex::Expr)
    if isexpr(ex, :comparison)
        return true
    elseif isexpr(ex, :call)
        if ex.args[1] in (:<=, :≤, :>=, :≥, :(==))
            return true
        else
            return false
        end
    else
        return false
    end
end

# x[i=1] <= 2 is a somewhat common user error. Catch it here.
function _has_assignment_in_ref(ex::Expr)
    if isexpr(ex, :ref)
        return any(x -> isexpr(x, :(=)), ex.args)
    else
        return any(_has_assignment_in_ref, ex.args)
    end
end
_has_assignment_in_ref(other) = false

function rewrite_sum(terms, current::Symbol, lcoeffs::Vector, rcoeffs::Vector, output::Symbol, block = Expr(:block))
    var = current
    for term in terms[1:(end-1)]
        var, code = _rewrite(term, var, lcoeffs, rcoeffs)
        push!(block.args, code)
    end
    new_output, code = _rewrite(terms[end], var, lcoeffs, rcoeffs, output)
    @assert new_output == output
    push!(block.args, code)
    return output, block
end

"""
    _rewrite(x, aff::Symbol, lcoeffs::Vector, rcoeffs::Vector, new_var::Symbol=gensym())

Return `new_var, code` such that `code` is equivalent to
```julia
new_var = aff + prod(lcoefs) * x * prod(rcoeffs)
```
"""
function _rewrite(x, aff::Symbol, lcoeffs::Vector, rcoeffs::Vector, new_var::Symbol=gensym())
    if isexpr(x, :call)
        if x.args[1] == :+
            return rewrite_sum(x.args[2:end], aff, lcoeffs, rcoeffs, new_var)
        elseif x.args[1] == :-
            block = Expr(:block)
            if length(x.args) > 2 # not unary subtraction
                aff_, code = _rewrite(x.args[2], aff, lcoeffs, rcoeffs)
                push!(block.args, code)
                start = 3
            else
                aff_ = aff
                start = 2
            end
            return rewrite_sum(x.args[start:end], aff_, vcat(-1, lcoeffs), rcoeffs, new_var, block)
        elseif x.args[1] == :*
            # we might need to recurse on multiple arguments, e.g.,
            # (x+y)*(x+y)
            n_expr = mapreduce(_is_complex_expr, +, x.args)
            if n_expr == 1 # special case, only recurse on one argument and don't create temporary objects
                which_idx = 0
                for i in 2:length(x.args)
                    if _is_complex_expr(x.args[i])
                        which_idx = i
                    end
                end
                return _rewrite(
                    x.args[which_idx], aff,
                    vcat(lcoeffs, [esc(x.args[i]) for i in 2:(which_idx - 1)]),
                    vcat(rcoeffs, [esc(x.args[i]) for i in (which_idx + 1):length(x.args)]),
                    new_var)
            else
                blk = Expr(:block)
                for i in 2:length(x.args)
                    if _is_complex_expr(x.args[i])
                        s = gensym()
                        new_var_, parsed = _rewrite_to(x.args[i], s)
                        push!(blk.args, :($s = MutableArithmetics.Zero(); $parsed))
                        x.args[i] = new_var_
                    else
                        x.args[i] = esc(x.args[i])
                    end
                end
                callexpr = Expr(:call, :(MutableArithmetics.add_mul!), aff,
                                lcoeffs..., x.args[2:end]..., rcoeffs...)
                push!(blk.args, :($new_var = $callexpr))
                return new_var, blk
            end
        elseif x.args[1] == :^ && _is_complex_expr(x.args[2])
            MulType = :(MA.promote_operation(*, typeof($(x.args[2])), typeof($(x.args[2]))))
            if x.args[3] == 2
                blk = Expr(:block)
                s = gensym()
                new_var_, parsed = _rewrite_to(x.args[2], s)
                push!(blk.args, :($s = MutableArithmetics.Zero(); $parsed))
                push!(blk.args, :($new_var = MutableArithmetics.add_mul!(
                    $aff, $(Expr(:call, :*, lcoeffs..., new_var_, new_var_,
                                 rcoeffs...)))))
                return new_var, blk
            elseif x.args[3] == 1
                return _rewrite(:(convert($MulType, $(x.args[2]))), aff, lcoeffs, rcoeffs, new_var)
            elseif x.args[3] == 0
                return _rewrite(:(one($MulType)), aff, lcoeffs, rcoeffs, new_var)
            else
                blk = Expr(:block)
                s = gensym()
                new_var_, parsed = _rewrite_to(x.args[2], s)
                push!(blk.args, :($s = MutableArithmetics.Zero(); $parsed))
                push!(blk.args, :($new_var = MutableArithmetics.add_mul!(
                    $aff, $(Expr(:call, :*, lcoeffs...,
                                 Expr(:call, :^, new_var_, esc(x.args[3])),
                                      rcoeffs...)))))
                return new_var, blk
            end
        elseif x.args[1] == :/
            @assert length(x.args) == 3
            numerator = x.args[2]
            denom = x.args[3]
            return _rewrite(numerator, aff, lcoeffs, vcat(esc(:(1 / $denom)), rcoeffs), new_var)
        elseif length(x.args) >= 2 && (isexpr(x.args[2], :generator) || isexpr(x.args[2], :flatten))
            return new_var, _parse_generator(x, aff, lcoeffs, rcoeffs, new_var)
        end
    elseif isexpr(x, :curly)
        Base.error("The curly syntax (sum{},prod{},norm2{}) is no longer supported. Expression: $x.")
    end
    if isa(x, Expr) && _is_comparison(x)
        error("Unexpected comparison in expression $x.")
    end
    if isa(x, Expr) && _has_assignment_in_ref(x)
        @warn "Unexpected assignment in expression $x. This will" *
                     " become a syntax error in a future release."
    end
    # at the lowest level
    callexpr = Expr(:call, :(MutableArithmetics.add_mul!), aff, lcoeffs..., esc(x), rcoeffs...)
    return new_var, :($new_var = $callexpr)
end
