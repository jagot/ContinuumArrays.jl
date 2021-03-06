abstract type Basis{T} <: LazyQuasiMatrix{T} end
abstract type Weight{T} <: LazyQuasiVector{T} end


const WeightedBasis{T, A<:AbstractQuasiVector, B<:Basis} = BroadcastQuasiMatrix{T,typeof(*),<:Tuple{A,B}}

struct WeightLayout <: MemoryLayout end
abstract type AbstractBasisLayout <: MemoryLayout end
struct BasisLayout <: AbstractBasisLayout end
struct SubBasisLayout <: AbstractBasisLayout end
struct MappedBasisLayout <: AbstractBasisLayout end
struct WeightedBasisLayout <: AbstractBasisLayout end

abstract type AbstractAdjointBasisLayout <: MemoryLayout end
struct AdjointBasisLayout <: AbstractAdjointBasisLayout end
struct AdjointSubBasisLayout <: AbstractAdjointBasisLayout end
struct AdjointMappedBasisLayout <: AbstractAdjointBasisLayout end

MemoryLayout(::Type{<:Basis}) = BasisLayout()
MemoryLayout(::Type{<:Weight}) = WeightLayout()

adjointlayout(::Type, ::BasisLayout) = AdjointBasisLayout()
adjointlayout(::Type, ::SubBasisLayout) = AdjointSubBasisLayout()
adjointlayout(::Type, ::MappedBasisLayout) = AdjointMappedBasisLayout()
broadcastlayout(::Type{typeof(*)}, ::WeightLayout, ::BasisLayout) = WeightedBasisLayout()
broadcastlayout(::Type{typeof(*)}, ::WeightLayout, ::SubBasisLayout) = WeightedBasisLayout()

combine_mul_styles(::AbstractBasisLayout) = LazyQuasiArrayApplyStyle()
combine_mul_styles(::AbstractAdjointBasisLayout) = LazyQuasiArrayApplyStyle()

ApplyStyle(::typeof(pinv), ::Type{<:Basis}) = LazyQuasiArrayApplyStyle()
pinv(J::Basis) = apply(pinv,J)


function ==(A::Basis, B::Basis)
    axes(A) == axes(B) && throw(ArgumentError("Override == to compare bases of type $(typeof(A)) and $(typeof(B))"))
    false
end

@inline quasildivapplystyle(::AbstractBasisLayout, ::AbstractBasisLayout) = LdivApplyStyle()
@inline quasildivapplystyle(::AbstractBasisLayout, _) = LdivApplyStyle()
@inline quasildivapplystyle(_, ::AbstractBasisLayout) = LdivApplyStyle()


@inline copy(L::Ldiv{<:AbstractBasisLayout,BroadcastLayout{typeof(+)}}) = +(broadcast(\,Ref(L.A),arguments(L.B))...)
@inline copy(L::Ldiv{<:AbstractBasisLayout,BroadcastLayout{typeof(+)},<:Any,<:AbstractQuasiVector}) = 
    transform_ldiv(L.A, L.B)

@inline function copy(L::Ldiv{<:AbstractBasisLayout,BroadcastLayout{typeof(-)}})
    a,b = arguments(L.B)
    (L.A\a)-(L.A\b)
end

@inline copy(L::Ldiv{<:AbstractBasisLayout,BroadcastLayout{typeof(-)},<:Any,<:AbstractQuasiVector}) =
    transform_ldiv(L.A, L.B)

function copy(P::Ldiv{BasisLayout,BasisLayout})
    A, B = P.A, P.B
    A == B || throw(ArgumentError("Override copy for $(typeof(A)) \\ $(typeof(B))"))
    SquareEye{eltype(P)}(size(A,2))
end
function copy(P::Ldiv{SubBasisLayout,SubBasisLayout})
    A, B = P.A, P.B
    (parent(A) == parent(B) && parentindices(A) == parentindices(B)) ||
        throw(ArgumentError("Override copy for $(typeof(A)) \\ $(typeof(B))"))
    SquareEye{eltype(P)}(size(A,2))
end

@inline function copy(P::Ldiv{MappedBasisLayout,MappedBasisLayout})
    A, B = P.A, P.B
    demap(A)\demap(B)
end

@inline copy(L::Ldiv{BasisLayout,SubBasisLayout}) = apply(\, L.A, ApplyQuasiArray(L.B))
@inline function copy(L::Ldiv{SubBasisLayout,BasisLayout}) 
    P = parent(L.A)
    kr, jr = parentindices(L.A)
    lazy_getindex(apply(\, P, L.B), jr, :) # avoid sparse arrays
end


for Bas1 in (:Basis, :WeightedBasis), Bas2 in (:Basis, :WeightedBasis)
    @eval ==(A::SubQuasiArray{<:Any,2,<:$Bas1}, B::SubQuasiArray{<:Any,2,<:$Bas2}) =
        all(parentindices(A) == parentindices(B)) && parent(A) == parent(B)
end


# expansion
_grid(_, P) = error("Overload Grid")
_grid(::MappedBasisLayout, P) = igetindex.(Ref(parentindices(P)[1]), grid(demap(P)))
_grid(::SubBasisLayout, P) = grid(parent(P))
_grid(::WeightedBasisLayout, P) = grid(last(P.args))
grid(P) = _grid(MemoryLayout(typeof(P)), P)

struct TransformFactorization{T,Grid,Plan,IPlan} <: Factorization{T}
    grid::Grid
    plan::Plan
    iplan::IPlan
end

TransformFactorization(grid, plan) = 
    TransformFactorization{promote_type(eltype(grid),eltype(plan)),typeof(grid),typeof(plan),Nothing}(grid, plan, nothing)


TransformFactorization(grid, ::Nothing, iplan) = 
    TransformFactorization{promote_type(eltype(grid),eltype(iplan)),typeof(grid),Nothing,typeof(iplan)}(grid, nothing, iplan)

grid(T::TransformFactorization) = T.grid    

\(a::TransformFactorization{<:Any,<:Any,Nothing}, b::AbstractQuasiVector) = a.iplan \  convert(Array, b[a.grid])
\(a::TransformFactorization, b::AbstractQuasiVector) = a.plan * convert(Array, b[a.grid])

\(a::TransformFactorization{<:Any,<:Any,Nothing}, b::AbstractVector) = a.iplan \  b
\(a::TransformFactorization, b::AbstractVector) = a.plan * b

function _factorize(::AbstractBasisLayout, L)
    p = grid(L)
    TransformFactorization(p, nothing, factorize(L[p,:]))
end

struct ProjectionFactorization{T, FAC<:Factorization{T}, INDS} <: Factorization{T}
    F::FAC
    inds::INDS
end

\(a::ProjectionFactorization, b::AbstractQuasiVector) = (a.F \ b)[a.inds]
\(a::ProjectionFactorization, b::AbstractVector) = (a.F \ b)[a.inds]

_factorize(::SubBasisLayout, L) = ProjectionFactorization(factorize(parent(L)), parentindices(L)[2])

transform_ldiv(A, B, _) = factorize(A) \ B
transform_ldiv(A, B) = transform_ldiv(A, B, axes(A))

copy(L::Ldiv{<:AbstractBasisLayout,<:Any,<:Any,<:AbstractQuasiVector}) =
    transform_ldiv(L.A, L.B)

copy(L::Ldiv{<:AbstractBasisLayout,ApplyLayout{typeof(*)},<:Any,<:AbstractQuasiVector}) =
    transform_ldiv(L.A, L.B)

function copy(L::Ldiv{ApplyLayout{typeof(*)},<:AbstractBasisLayout})
    args = arguments(L.A)
    @assert length(args) == 2 # temporary
    apply(\, last(args), apply(\, first(args), L.B))
end


function copy(L::Ldiv{<:AbstractBasisLayout,BroadcastLayout{typeof(*)},<:AbstractQuasiMatrix,<:AbstractQuasiVector})
    p,T = factorize(L.A)
    T \ L.B[p]
end

## materialize views

# materialize(S::SubQuasiArray{<:Any,2,<:ApplyQuasiArray{<:Any,2,typeof(*),<:Tuple{<:Basis,<:Any}}}) =
#     *(arguments(S)...)



# mass matrix
# y = p(x), dy = p'(x) * dx
# \int_a^b f(y) g(y) dy = \int_{-1}^1 f(p(x))*g(p(x)) * p'(x) dx


_sub_getindex(A, kr, jr) = A[kr, jr]
_sub_getindex(A, ::Slice, ::Slice) = A

function copy(M::QMul2{<:QuasiAdjoint{<:Any,<:SubQuasiArray{<:Any,2,<:AbstractQuasiMatrix,<:Tuple{<:AbstractAffineQuasiVector,<:Any}}},
                        <:SubQuasiArray{<:Any,2,<:AbstractQuasiMatrix,<:Tuple{<:AbstractAffineQuasiVector,<:Any}}})
    Ac, B = M.args
    A = Ac'
    PA,PB = parent(A),parent(B)
    kr,jr = parentindices(B)
    _sub_getindex((PA'PB)/kr.A,parentindices(A)[2],jr)
end


# Differentiation of sub-arrays
function copy(M::QMul2{<:Derivative,<:SubQuasiArray{<:Any,2,<:AbstractQuasiMatrix,<:Tuple{<:Inclusion,<:Any}}})
    A, B = M.args
    P = parent(B)
    (Derivative(axes(P,1))*P)[parentindices(B)...]
end

function copy(M::QMul2{<:Derivative,<:SubQuasiArray{<:Any,2,<:AbstractQuasiMatrix,<:Tuple{<:AbstractAffineQuasiVector,<:Any}}})
    A, B = M.args
    P = parent(B)
    kr,jr = parentindices(B)
    (Derivative(axes(P,1))*P*kr.A)[kr,jr]
end

function copy(L::Ldiv{<:AbstractBasisLayout,BroadcastLayout{typeof(*)},<:AbstractQuasiMatrix})
    args = arguments(L.B)
    # this is a temporary hack
    if args isa Tuple{AbstractQuasiMatrix,Number}
        (L.A \  first(args))*last(args)
    elseif args isa Tuple{Number,AbstractQuasiMatrix}
        first(args)*(L.A \ last(args))
    else
        error("Not implemented")
    end
end


# we represent as a Mul with a banded matrix
sublayout(::AbstractBasisLayout, ::Type{<:Tuple{<:Inclusion,<:AbstractUnitRange}}) = SubBasisLayout()
sublayout(::AbstractBasisLayout, ::Type{<:Tuple{<:AbstractAffineQuasiVector,<:AbstractUnitRange}}) = MappedBasisLayout()

@inline sub_materialize(::AbstractBasisLayout, V::AbstractQuasiArray) = V
@inline sub_materialize(::AbstractBasisLayout, V::AbstractArray) = V

demap(x) = x
demap(V::SubQuasiArray{<:Any,2,<:Any,<:Tuple{<:Any,<:Slice}}) = parent(V)
function demap(V::SubQuasiArray{<:Any,2}) 
    kr, jr = parentindices(V)
    demap(parent(V)[kr,:])[:,jr]
end


##
# SubLayout behaves like ApplyLayout{typeof(*)}

combine_mul_styles(::SubBasisLayout) = combine_mul_styles(ApplyLayout{typeof(*)}())
_arguments(::SubBasisLayout, A) = _arguments(ApplyLayout{typeof(*)}(), A)
call(::SubBasisLayout, ::SubQuasiArray) = *

combine_mul_styles(::AdjointSubBasisLayout) = combine_mul_styles(ApplyLayout{typeof(*)}())
_arguments(::AdjointSubBasisLayout, A) = _arguments(ApplyLayout{typeof(*)}(), A)
arguments(::AdjointSubBasisLayout, A) = arguments(ApplyLayout{typeof(*)}(), A)
call(::AdjointSubBasisLayout, ::SubQuasiArray) = *

function arguments(V::SubQuasiArray{<:Any,2,<:Any,<:Tuple{<:Inclusion,<:AbstractUnitRange}})
    A = parent(V)
    _,jr = parentindices(V)
    first(jr) ≥ 1 || throw(BoundsError())
    P = _BandedMatrix(Ones{Int}(1,length(jr)), axes(A,2), first(jr)-1,1-first(jr))
    A,P
end

####
# sum
####

_sum(V::AbstractQuasiArray, dims) = __sum(MemoryLayout(typeof(V)), V, dims)
_sum(V::AbstractQuasiArray, ::Colon) = __sum(MemoryLayout(typeof(V)), V, :)
sum(V::AbstractQuasiArray; dims=:) = _sum(V, dims)

__sum(L, Vm, _) = error("Override for $L")
function __sum(::SubBasisLayout, Vm, dims) 
    @assert dims == 1
    sum(parent(Vm); dims=dims)[:,parentindices(Vm)[2]]
end
function __sum(::ApplyLayout{typeof(*)}, V::AbstractQuasiVector, ::Colon)
    a = arguments(V)
    first(apply(*, sum(a[1]; dims=1), tail(a)...))
end

function __sum(::MappedBasisLayout, V::AbstractQuasiArray, dims)
    kr, jr = parentindices(V)
    @assert kr isa AbstractAffineQuasiVector
    sum(demap(V); dims=dims)/kr.A
end

include("splines.jl")
