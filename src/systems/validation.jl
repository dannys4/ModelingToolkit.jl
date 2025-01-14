Base.:*(x::Union{Num,Symbolic},y::Unitful.AbstractQuantity) = x * y
Base.:/(x::Union{Num,Symbolic},y::Unitful.AbstractQuantity) = x / y

struct ValidationError <: Exception
    message::String
end

function screen_unit(result)
    result isa Unitful.Unitlike || throw(ValidationError("Unit must be a subtype of Unitful.Unitlike, not $(typeof(result))."))
    result isa Unitful.ScalarUnits || throw(ValidationError("Non-scalar units such as $result are not supported. Use a scalar unit instead."))
    result == u"°" && throw(ValidationError("Degrees are not supported. Use radians instead."))
end
"Find the unit of a symbolic item."
get_unit(x::Real) = unitless
function get_unit(x::Unitful.Quantity) 
    result = Unitful.unit(x)
    screen_unit(result)
    return result
end
equivalent(x,y) = isequal(1*x,1*y)
unitless = Unitful.unit(1)

get_unit(x::Num) = get_unit(value(x))
function get_unit(x::Symbolic)
    if x isa Sym || operation(x) isa Sym || (operation(x) isa Term && operation(x).f == getindex) || x isa Symbolics.ArrayOp
        if x.metadata !== nothing
            symunits = get(x.metadata, VariableUnit, unitless)
            screen_unit(symunits)
        else
            symunits = unitless
        end
        return symunits
    elseif operation(x) isa Differential
        return get_unit(arguments(x)[1]) / get_unit(operation(x).x)
    elseif  operation(x) isa Difference
        return get_unit(arguments(x)[1]) / get_unit(operation(x).t) #TODO: make this same as Differential
    elseif x isa Pow
        pargs = arguments(x)
        base,expon = get_unit.(pargs)
        @assert expon isa Unitful.DimensionlessUnits
        if base == unitless
            unitless
        else 
            pargs[2] isa Number ? operation(x)(base, pargs[2]) : operation(x)(1*base, pargs[2])
        end
    elseif x isa Add # Cannot simply add the units b/c they may differ in magnitude (eg, kg vs g)
        terms = get_unit.(arguments(x))
        firstunit = terms[1]
        for other in terms[2:end]
            termlist = join(map(repr,terms),", ")
            equivalent(other,firstunit) || throw(ValidationError(", in sum $x, units [$termlist] do not match."))
        end
        return firstunit
    elseif operation(x) == Symbolics._mapreduce 
        if x.arguments[2] == +
            get_unit(x.arguments[3])
        else
            throw(ValidationError("Unsupported array operation $x"))
        end
    else
        return get_unit(operation(x)(1 .* get_unit.(arguments(x))...))
    end
end

"Get unit of term, returning nothing & showing warning instead of throwing errors."
function safe_get_unit(term, info)
    side = nothing
    try
        side = get_unit(term)
    catch err
        if err isa Unitful.DimensionError 
            @warn("$info: $(err.x) and $(err.y) are not dimensionally compatible.")
        elseif err isa ValidationError
            @warn(info*err.message)
        elseif err isa MethodError
            @warn("$info: no method matching $(err.f) for arguments $(typeof.(err.args)).")
        else
            rethrow()
        end
    end
    side
end

function _validate(terms::Vector, labels::Vector{String}; info::String = "")
    equnits = safe_get_unit.(terms, info*" ".*labels)
    allthere = all(map(x -> x!==nothing, equnits))
    allmatching = true
    first_unit = nothing
    if allthere
        for idx in 1:length(equnits)
            if !isequal(terms[idx],0)
                if first_unit === nothing
                    first_unit = equnits[idx]
                elseif !equivalent(first_unit, equnits[idx])
                    allmatching = false
                    @warn("$info: units [$(equnits[1])] for $(labels[1]) and [$(equnits[idx])] for $(labels[idx]) do not match.")
           
                end
            end
        end
    end
    allthere && allmatching
end

function validate(jump::Union{ModelingToolkit.VariableRateJump, ModelingToolkit.ConstantRateJump}, t::Symbolic; info::String = "")
    newinfo = replace(info,"eq."=>"jump") 
    _validate([jump.rate, 1/t], ["rate", "1/t"], info = newinfo) && # Assuming the rate is per time units
    validate(jump.affect!,info = newinfo)
end

function validate(jump::ModelingToolkit.MassActionJump, t::Symbolic; info::String = "")
    left_symbols = [x[1] for x in jump.reactant_stoch] #vector of pairs of symbol,int -> vector symbols
    net_symbols = [x[1] for x in jump.net_stoch]
    all_symbols = vcat(left_symbols,net_symbols)
    allgood = _validate(all_symbols, string.(all_symbols), info = info)
    n = sum(x->x[2],jump.reactant_stoch,init = 0)
    base_unitful = all_symbols[1] #all same, get first
    allgood && _validate([jump.scaled_rates, 1/(t*base_unitful^n)], ["scaled_rates", "1/(t*reactants^$n))"], info = info)
end

function validate(jumps::ArrayPartition{<:Union{Any, Vector{<:JumpType}}}, t::Symbolic)
    labels = ["in Mass Action Jumps,", "in Constant Rate Jumps,", "in Variable Rate Jumps,"]
    all([validate(jumps.x[idx], t, info = labels[idx]) for idx in 1:3])
end

validate(eq::ModelingToolkit.Equation; info::String = "") = _validate([eq.lhs, eq.rhs], ["left", "right"], info = info)
validate(eq::ModelingToolkit.Equation, term::Union{Symbolic,Unitful.Quantity,Num}; info::String = "") = _validate([eq.lhs, eq.rhs, term], ["left","right","noise"], info = info)
validate(eq::ModelingToolkit.Equation, terms::Vector; info::String = "") = _validate(vcat([eq.lhs, eq.rhs], terms), vcat(["left", "right"], "noise  #".*string.(1:length(terms))), info = info)

"Returns true iff units of equations are valid."
validate(eqs::Vector; info::String = "") = all([validate(eqs[idx], info = info*" in eq. #$idx") for idx in 1:length(eqs)])
validate(eqs::Vector, noise::Vector; info::String = "") = all([validate(eqs[idx], noise[idx], info = info*" in eq. #$idx") for idx in 1:length(eqs)])
validate(eqs::Vector, noise::Matrix; info::String = "") = all([validate(eqs[idx], noise[idx, :], info = info*" in eq. #$idx") for idx in 1:length(eqs)])
validate(eqs::Vector, term::Symbolic; info::String = "") = all([validate(eqs[idx], term, info = info*" in eq. #$idx") for idx in 1:length(eqs)])
validate(term::Symbolics.SymbolicUtils.Symbolic) = safe_get_unit(term,"") !== nothing

"Throws error if units of equations are invalid."
check_units(eqs...) = validate(eqs...) || throw(ValidationError("Some equations had invalid units. See warnings for details."))
