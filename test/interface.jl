using Test
import MutableArithmetics
const MA = MutableArithmetics

struct DummyMutable end

function MA.promote_operation(
    ::typeof(+),
    ::Type{DummyMutable},
    ::Type{DummyMutable},
)
    return DummyMutable
end
# Test that this does not triggers any ambiguity even if there is a fallback specific to `/`.
function MA.promote_operation(
    ::Union{typeof(-),typeof(/)},
    ::Type{DummyMutable},
    ::Type{DummyMutable},
)
    return DummyMutable
end
MA.mutability(::Type{DummyMutable}) = MA.IsMutable()

@testset "promote_operation" begin
    @test MA.promote_operation(/, Rational{Int}, Rational{Int}) == Rational{Int}
    @test MA.promote_operation(-, DummyMutable, DummyMutable) == DummyMutable
    @test MA.promote_operation(/, DummyMutable, DummyMutable) == DummyMutable
end

@testset "Errors" begin
    err = ArgumentError(
        "Cannot call `operate_to!(::$Int, +, ::$Int, ::$Int)` as objects of type `$Int` cannot be modifed to equal the result of the operation. Use `operate_to!!` instead which returns the value of the result (possibly modifying the first argument) to write generic code that also works when the type cannot be modified.",
    )
    @test_throws err MA.operate_to!(0, +, 0, 0)
    err = ArgumentError(
        "Cannot call `operate!(+, ::$Int, ::$Int)` as objects of type `$Int` cannot be modifed to equal the result of the operation. Use `operate!!` instead which returns the value of the result (possibly modifying the first argument) to write generic code that also works when the type cannot be modified.",
    )
    @test_throws err MA.operate!(+, 0, 0)
    err = ArgumentError(
        "Cannot call `buffered_operate_to!(::$Int, ::$Int, +, ::$Int, ::$Int)` as objects of type `$Int` cannot be modifed to equal the result of the operation. Use `buffered_operate_to!!` instead which returns the value of the result (possibly modifying the first argument) to write generic code that also works when the type cannot be modified.",
    )
    @test_throws err MA.buffered_operate_to!(0, 0, +, 0, 0)
    err = ArgumentError(
        "Cannot call `buffered_operate!(::$Int, +, ::$Int, ::$Int)` as objects of type `$Int` cannot be modifed to equal the result of the operation. Use `buffered_operate!!` instead which returns the value of the result (possibly modifying the first argument) to write generic code that also works when the type cannot be modified.",
    )
    @test_throws err MA.buffered_operate!(0, +, 0, 0)
    x = DummyMutable()
    err = ErrorException(
        "`operate_to!(::DummyMutable, +, ::DummyMutable, ::DummyMutable)` is not implemented yet.",
    )
    @test_throws err MA.operate_to!(x, +, x, x)
    err = ErrorException(
        "`operate!(+, ::DummyMutable, ::DummyMutable)` is not implemented yet.",
    )
    @test_throws err MA.operate!(+, x, x)
    err = ErrorException(
        "`buffered_operate_to!(::DummyMutable, ::DummyMutable, +, ::DummyMutable, ::DummyMutable)` is not implemented.",
    )
    @test_throws err MA.buffered_operate_to!(x, x, +, x, x)
    err = ErrorException(
        "`buffered_operate!(::DummyMutable, +, ::DummyMutable, ::DummyMutable)` is not implemented.",
    )
    @test_throws err MA.buffered_operate!(x, +, x, x)
end
