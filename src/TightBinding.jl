module TightBinding

using LinearAlgebra
using SymEngine
using Match

using BenchmarkTools

abstract type Model end
abstract type Sample end

struct TB_Model_with_Parameter <: Model
	model_name::String
	parameter_list::Vector{SymEngine.Basic}
	dim::Int64
	nsub::Int64
	basis_vectors::Vector{Vector{Float64}}
	sublattice_positions::Vector{Vector{Float64}}
	atom_name_list::Vector{String}
	unit_cell_volume::Float64
	reciprocal_basis_vectors::Vector{Vector{Float64}}
	k_crystal::Vector{SymEngine.Basic}
	k_cartesian::Vector{SymEngine.Basic}
	
	hopping_hashmap::Dict{Vector{Vector{Int64}}, SymEngine.Basic}
	H_crystal::Matrix{SymEngine.Basic}
	H_cartesian::Matrix{SymEngine.Basic}
end

struct Bilinear # [adagger]_{to_site}.amplitude.[a]_{from_site}
	to_site::Vector{Int64}
	from_site::Vector{Int64}
	amplitude::ComplexF64
end

struct TB_Model <: Model
	model_with_parameter::TB_Model_with_Parameter
	parameter_settings::Dict{SymEngine.Basic, Float64}

	Hk_crystal::Function
	Hk_cartesian::Function
	hopping_term_list::Vector{Bilinear}
end


struct TB_Sample <: Sample
	tb_model::TB_Model
	sample_size::Vector{Int64}
	boundary_flux::Vector{Int64}
	temperature::Float64

	# states are labelled with a tuple (i,j,k,nsub)
	state_to_r_crystal_hashmap::Dict{NTuple{4,Int64}, Vector{Float64}}
	state_to_k_crystal_hashmap::Dict{NTuple{4,Int64}, Vector{Float64}}
	state_to_eigs_hashmap::Dict{NTuple{4,Int64},Tuple{Float64, Vector{ComplexF64}}}
end


"""
#### Create a C structure symbolic variable (with specific memory address)
> The usage is extracted from https://github.com/symengine/SymEngine.jl/blob/master/src/types.jl
"""
function SymEngine_var_creation(s::String)
	a = Basic()
	ccall((:symbol_set, SymEngine.libsymengine), Nothing, (Ref{Basic}, Ptr{Int8}), a, s)
	return a
end
SymEngine_var_creation(s::Symbol) = SymEngine_var_creation(string(s))


###=================================================================###
###============== Main Generation Functions Start Here =============###
###=================================================================###
"""
#### Initialize a Tightbinding Model with Parameters.
> The structure is read from the file `tb_model.txt` by default, but you can assign by yourself through
> ```julia
> initialize_model_with_param(tb_filename="...")
> ```
"""
function initialize_model_with_param(; tb_filename::String="tb_model.txt")
	model_name = ""
	atom_name_list::Vector{String} = []
    parameter_list::Vector{SymEngine.Basic} = []

	k_crystal = (SymEngine.@vars k1 k2 k3) |> collect # convert to Vector{SymEngine.Basic}
	k_cartesian = (SymEngine.@vars kx ky kz)  |> collect

	f = open(tb_filename, "r")
	tb_model_txt_lists = split(read(f, String),"\n") # Read the entire content and split it into vectors of strings

    let parameter_line = Meta.parse.(split(tb_model_txt_lists[1], " "))
        for s in parameter_line
            eval(Expr(:(=), s, Expr(:call, :SymEngine_var_creation, Expr(:quote, s)))) # automatic escape for lazy evaluation (necessary for further usage)
            push!(parameter_list, SymEngine_var_creation(s))
        end
    end

    model_name = tb_model_txt_lists[2]
    print("Model Name: "); printstyled(model_name, "\n"; color=:blue, underline=true) # colorful output
    print("Parameters: "); printstyled(parameter_list, "\n"; color=:blue)

	# Parse String into Symbol and evaluate it
	basis_vectors = eval(Meta.parse(tb_model_txt_lists[3])) # the result type is a M-vector of N-vector
	
	# `sublattice_positions` saves the atom positions within each unit cell in the crystal coordinate (NOT cartesian coordinate!)
    sublattice_positions = eval(Meta.parse(tb_model_txt_lists[4])) # the result type is a M-vector of N-vector
	sublattice_positions = convert(Vector{Vector{Float64}}, sublattice_positions)
    # sublattice_positions = convert(Matrix{Float64}, reduce(hcat, sublattice_positions)) # convert to a N*M matrix, so that the i-th components of the sublattice vector is sublattice_positions[:,i]
    #(dim, nsub) = size(sublattice_positions) # size(sublattice_positions) = (dim, nsub)
	nsub = length(sublattice_positions)
	dim = length(sublattice_positions[1]) # or length(basis_vectors)

	# truncate to the appropriate dimention
    k_crystal = k_crystal[1:dim]
    k_cartesian = k_cartesian[1:dim]

    atom_name_list = eval(Meta.parse.(tb_model_txt_lists[5])) # Meta.parse must acts through the Array{String,1}
	if length(atom_name_list) != nsub
		atom_name_list = fill("", nsub) # fill empty atom names
	end

	# Now let us construct the Hamiltonian and the hashmap for hoppings under the cystal coordinates (rather than the cartesian coordinate!)
	H_crystal = zeros(SymEngine.Basic, (nsub,nsub))

    hoppint_strings = tb_model_txt_lists[6:end]; filter!(!isempty, hoppint_strings) # read the left contents, and remove all empty strings
	hopping_hashmap = Dict{Vector{Vector{Int64}}, SymEngine.Basic}();
	sizehint!(hopping_hashmap, length(hoppint_strings)) # preallocation is good for performance
	
	for i in eachindex(hoppint_strings)
		let single_hopping_string = Meta.parse(hoppint_strings[i]) # type{Expr}
			if single_hopping_string.head == :vect
				let (to_site, from_site, tunneling) = single_hopping_string.args
					to_site = eval(to_site) # Int64 is converted to SymEngine.Basic so that the structure has a coherent type
					from_site = eval(from_site)
					tunneling = eval(tunneling)[1] # force converting it to SymEngine.Basic

					let hopping_term::Vector{Vector{Int64}} = [to_site,from_site]
						@inbounds hopping_hashmap[hopping_term] = tunneling
						_add_one_term_to_H_crystal!(to_site, from_site, t, sublattice_positions, k_crystal, H_crystal)
					end
				end
			end
		end
	end


	# reciprocal vectors
	@match dim begin
		2 => begin # fill zero for the extra dimensions
				push!(basis_vectors[1],0); push!(basis_vectors[2],0); push!(basis_vectors, [0,0,1])

				unit_cell_volume = @inbounds dot(basis_vectors[1], cross(basis_vectors[2], basis_vectors[3]))
				reciprocal_basis_vectors = Vector{Vector{Float64}}(undef, 3)
				for i in 1:3
					reciprocal_basis_vectors[i] = convert(Vector{Float64}, cross(basis_vectors[mod1(i+1,3)], basis_vectors[mod1(i+2,3)]))
					# a trick for cyclic indexing; Note that mod1(a,a)==a
				end
				reciprocal_basis_vectors = 2*pi/unit_cell_volume * reciprocal_basis_vectors
				basis_vectors = [@inbounds basis_vectors[i][1:2] for i in 1:2]
				reciprocal_basis_vectors = [@inbounds reciprocal_basis_vectors[i][1:2] for i in 1:2]
				# transition_matrix_between_kcrystal_and_kcartesian 
				U = 2*pi*inv(reduce(hcat, reciprocal_basis_vectors)[1:2,1:2])*k_cartesian
				H_cartesian = @inbounds SymEngine.subs.(H_crystal, k1=>U[1], k2=>U[2])
			end
		3 => begin
				unit_cell_volume = @inbounds dot(basis_vectors[1], cross(basis_vectors[2], basis_vectors[3]))
				reciprocal_basis_vectors = Vector{Vector{Float64}}(undef, 3)
				for i in 1:3
					reciprocal_basis_vectors[i] = convert(Vector{Float64}, cross(basis_vectors[mod1(i+1,3)], basis_vectors[mod1(i+2,3)]))
					# a trick for cyclic indexing; Note that mod1(a,a)==a
				end
				reciprocal_basis_vectors = 2*pi/unit_cell_volume * reciprocal_basis_vectors
				# transition_matrix_between_kcrystal_and_kcartesian 
				U = 2*pi*inv(reduce(hcat, reciprocal_basis_vectors))*k_cartesian
				H_cartesian = @inbounds SymEngine.subs.(H_crystal, k1=>U[1], k2=>U[2])
				H_cartesian = @inbounds SymEngine.subs.(H_crystal, k1=>U[1], k2=>U[2], k3=>U[3])
			end
		_ => error("Dimension Error!")
	end

	return TB_Model_with_Parameter(
			model_name,
			parameter_list,
			dim,
			nsub,
			basis_vectors,
			sublattice_positions,
			atom_name_list,
			unit_cell_volume,
			reciprocal_basis_vectors,
			k_crystal,
			k_cartesian,
			
			hopping_hashmap,
			H_crystal,
			H_cartesian
	)
end


"""
#### Initialize a Tightbinding Model with All Parameters Set
> The structure is read from the file `tb_model.txt` by default, but you can still assign by yourself. The parameter settings are set to be an empty tuple `param=()` of unkown element of type `Tuple{Pair{String, Float64}}` by default (thanks to `Type{Vararg}`). But you can insert through
> ```julia
> initialize_model_with_param(param = ("mu"=>1.0,"nu"=>2.0, ...); tb_filename="...")
> ```
"""
function initialize_model(param::Tuple{T, Vararg{T}}=(); tb_filename::String="tb_model.txt") where T<:Pair{String, Float64}
	model = initialize_model_with_param(; tb_filename)
	
	H_crystal = model.H_crystal
	H_cartesian = model.H_cartesian
	
	#set parameters
	rules = Dict{SymEngine.Basic, Float64}()
	for pair in param
		let s = Meta.parse(pair[1])
			# claim symbolic variables (in case of the situation when the assigning parameters are not claimed yet)
			eval(Expr(:(=), s, Expr(:call, :SymEngine_var_creation, Expr(:quote, s)))) 
			rules[SymEngine_var_creation(s)] = pair[2]
		end
	end
	print("Parameter Settings: "); printstyled(rules, "\n"; color=:blue)

	(Hk_crystal_symbolic, Hk_cartesian_symbolic) = map(H->SymEngine.subs.(H, Ref(rules)), (H_crystal, H_cartesian))
	# if all parameters are set, then Hk_crystal should only contains symbolic variables like k1,k2,k3
	if length(SymEngine.free_symbols.(Hk_crystal_symbolic)) > model.dim
		error("Some Parameters are not set yet!")
	else
		Hk_crystal(kpoints::Number...) = convert(Matrix{ComplexF64}, SymEngine.subs.(Hk_crystal_symbolic, Ref(Dict(Pair.(model.k_crystal, kpoints)))))
		Hk_cartesian(kpoints::Number...) = convert(Matrix{ComplexF64}, SymEngine.subs.(Hk_cartesian_symbolic, Ref(Dict(Pair.(model.k_cartesian, kpoints)))))
	end

	hopping_term_list = Vector{Bilinear}()
	let hopping_hashmap = model.hopping_hashmap
		sizehint!(hopping_term_list, length(hopping_hashmap))
		for (k,v) in hopping_hashmap
			push!(hopping_term_list, Bilinear(k[1], k[2], convert(ComplexF64, SymEngine.subs.(v, Ref(rules)))) )
		end
	end

	return TB_Model(
		model,
		rules,
		Hk_crystal,
		Hk_cartesian,
		hopping_term_list
	)
end



"""
#### realize a Finite-size Tightbinding Sample
> The sample size is set through, for example:
> ```julia
> initialize_sample(model; sample_size=[6,6,6], boundary_flux=[0,0,0], tempearture=1.0E-6)
> ```
> We use `(i,j,k,nsub)` to label the states, so that each physical quantities `Q` of the sample is saved as a `HashMap<state,Q>`. Note: here for consistency we keep the third index (=1) even for two-dimensional systems.
"""
function initialize_sample(model::TB_Model; sample_size::Vector{Int64}=[6,6,6], boundary_flux::Vector{Int64}=[0,0,0], temperature::Float64=1.0E-6)
	let m = model.model_with_parameter
		L_tuple = (Lx,Ly,Lz) = tuple(sample_size...)
		@assert Lx>0 && Ly>0 && Lz>0
		L_tot = reduce(*, L_tuple)

		dim = m.dim
		nsub = m.nsub

		# we use the tuple `(i,j,k,nsub)` to denote each state (if the tightbinding model is a two-dimensional system, then `k` is always 1)
		state_to_k_crystal_hashmap = Dict{NTuple{4, Int64}, Vector{Float64}}()
		sizehint!(state_to_k_crystal_hashmap, L_tot*nsub)
		for i in 1:Lx, j in 1:Ly, k in 1:Lz, sub in 1:nsub
			state_to_k_crystal_hashmap[(i,j,k,sub)] = [
				((i-1)*2*pi+boundary_flux[1])/Lx,
				((j-1)*2*pi+boundary_flux[2])/Ly,
				((k-1)*2*pi+boundary_flux[3])/Lz
			]
		end

		state_to_r_crystal_hashmap = Dict{NTuple{4, Int64}, Vector{Float64}}()
		sizehint!(state_to_r_crystal_hashmap, L_tot*nsub)
		for i in 1:Lx, j in 1:Ly, k in 1:Lz, sub in 1:nsub
			state_to_r_crystal_hashmap[(i,j,k,sub)] = begin
				@match dim begin
					2 => _r_crystal([i,j,sub], m.sublattice_positions)
					3 => _r_crystal([i,j,k,sub], m.sublattice_positions)
				end
			end
		end
		
		state_to_eigs_hashmap = Dict{NTuple{4, Int64}, Tuple{Float64, Vector{ComplexF64}}}()
		sizehint!(state_to_eigs_hashmap, L_tot*nsub)
		for (key, val) in state_to_k_crystal_hashmap
			let k_crystal_point = collect(val)
				eigs = eigen_k_crystal(k_crystal_point, model)
				let sub = key[end]
					state_to_eigs_hashmap[key] = @inbounds (eigs.values[sub], eigs.vectors[:,sub])
				end
			end
		end

		@show state_to_eigs_hashmap

		return TB_Sample(
			model,
			sample_size,
			boundary_flux,
			temperature,

			state_to_r_crystal_hashmap,
			state_to_k_crystal_hashmap,
			state_to_eigs_hashmap
		)
	end
end


###=================================================================###
###================= Auxilary Function Start Here ==================###
###=================================================================###
"push one hopping term to the symbolic Hamiltonian"
@inline function _add_one_term_to_H_crystal!(to_site::Vector{Int64}, from_site::Vector{Int64}, t::SymEngine.Basic, sublattice_positions::Vector{Vector{Float64}}, k_crystal::Vector{SymEngine.Basic}, H_crystal::Matrix{SymEngine.Basic})
	from_site_position = _r_crystal(from_site, sublattice_positions)
	to_site_position = _r_crystal(to_site, sublattice_positions)
	displacement = to_site_position - from_site_position
	φ = dot(displacement, k_crystal)
	H_crystal[to_site[end], from_site[end]] += t*exp(-im*φ)
end

"get the crystal coordinate for a given site [i,j,k,sub]"
@inline function _r_crystal(site::Vector{Int64}, sublattice_positions::Vector{Vector{Float64}})::Vector{Float64}
	return site[1:end-1] + sublattice_positions[site[end]]
end

"return the eigen system at k_crystal_point [i,j,k]"
@inline function eigen_k_crystal(k_crystal_point::Vector{Float64}, model::TB_Model)
	let dim = model.model_with_parameter.dim
		return eigen(Hermitian(model.Hk_crystal(k_crystal_point[1:dim]...)))
	end
end

end