
function _build_constraint_coefficients_matrix_in_ref_space(Dc, reffe::Tuple{<:Lagrangian,Any,Any})
    function _h_refined_reffe(reffe::Tuple{<:Lagrangian,Any,Any})
        (reffe[1], (reffe[2][1], 2 * reffe[2][2]), reffe[3])
    end
    cell_polytope = Dc == 2 ? QUAD : HEX
    basis, reffe_args, reffe_kwargs = reffe
    cell_reffe = ReferenceFE(cell_polytope, basis, reffe_args...; reffe_kwargs...)
    h_refined_reffe = _h_refined_reffe(reffe)
    basis, reffe_args, reffe_kwargs = h_refined_reffe
    cell_reffe_h_refined = ReferenceFE(cell_polytope, basis, reffe_args...; reffe_kwargs...)
    dof_basis_h_refined = Gridap.CellData.get_dof_basis(cell_reffe_h_refined)
    coarse_shape_funs = Gridap.ReferenceFEs.get_shapefuns(cell_reffe)
    ref_constraints = evaluate(dof_basis_h_refined, coarse_shape_funs)
end

# To-think: might this info go to the glue? 
# If it is required in different scenarios, I would say it may make sense
function _generate_hanging_faces_to_cell_and_lface(num_regular_faces,
    num_hanging_faces,
    gridap_cell_faces)
    # Locate for each hanging vertex a cell to which it belongs 
    # and local position within that cell 
    hanging_faces_to_cell = Vector{Int}(undef, num_hanging_faces)
    hanging_faces_to_lface = Vector{Int}(undef, num_hanging_faces)
    for cell = 1:length(gridap_cell_faces)
        s = gridap_cell_faces.ptrs[cell]
        e = gridap_cell_faces.ptrs[cell+1]
        l = e - s
        for j = 1:l
            fid = gridap_cell_faces.data[s+j-1]
            if fid > num_regular_faces
                fid_hanging = fid - num_regular_faces
                hanging_faces_to_cell[fid_hanging] = cell
                hanging_faces_to_lface[fid_hanging] = j
            end
        end
    end
    hanging_faces_to_cell, hanging_faces_to_lface
end

function _generate_hanging_faces_owner_face_dofs(num_hanging_faces,
    face_dofs,
    hanging_faces_glue,
    cell_dof_ids)

    cache = array_cache(cell_dof_ids)
    ptrs = Vector{Int}(undef, num_hanging_faces + 1)
    ptrs[1] = 1
    for fid_hanging = 1:num_hanging_faces
        glue = hanging_faces_glue[fid_hanging]
        ocell_lface = glue[2]
        ptrs[fid_hanging+1] = ptrs[fid_hanging] + length(face_dofs[ocell_lface])
    end
    data_owner_face_dofs = Vector{Int}(undef, ptrs[num_hanging_faces+1] - 1)
    for fid_hanging = 1:num_hanging_faces
        glue = hanging_faces_glue[fid_hanging]
        ocell = glue[1]
        ocell_lface = glue[2]
        s = ptrs[fid_hanging]
        e = ptrs[fid_hanging+1] - 1
        current_cell_dof_ids = getindex!(cache, cell_dof_ids, ocell)
        for (j, ldof) in enumerate(face_dofs[ocell_lface])
            data_owner_face_dofs[s+j-1] = current_cell_dof_ids[ldof]
        end
    end
    Gridap.Arrays.Table(data_owner_face_dofs, ptrs)
end

function face_dim(::Type{Val{Dc}}, face_lid) where {Dc}
    num_vertices = GridapP4est.num_cell_vertices(Val{Dc})
    num_edges = GridapP4est.num_cell_edges(Val{Dc})
    num_faces = GridapP4est.num_cell_faces(Val{Dc})
    if (face_lid <= num_vertices)
        return 0
    elseif (face_lid <= num_vertices + num_edges)
        return 1
    elseif (face_lid <= num_vertices + num_edges + num_faces)
        return Dc - 1
    end
end

function face_lid_within_dim(::Type{Val{Dc}}, face_lid) where {Dc}
    num_vertices = GridapP4est.num_cell_vertices(Val{Dc})
    num_edges = GridapP4est.num_cell_edges(Val{Dc})
    num_faces = GridapP4est.num_cell_faces(Val{Dc})
    if (face_lid <= num_vertices)
        return face_lid
    elseif (face_lid <= num_vertices + num_edges)
        return face_lid - num_vertices
    elseif (face_lid <= num_vertices + num_edges + num_faces)
        return face_lid - num_vertices - num_edges
    end
end

function _generate_constraints!(Df,
    Dc,
    cell_faces,
    num_hanging_faces,
    hanging_faces_to_cell,
    hanging_faces_to_lface,
    hanging_faces_owner_face_dofs,
    hanging_faces_glue,
    face_subface_ldof_to_cell_ldof,
    face_dofs,
    face_own_dofs,
    subface_own_dofs,
    cell_dof_ids,
    node_permutations,
    owner_faces_pindex,
    owner_faces_lids,
    ref_constraints,
    sDOF_to_dof,
    sDOF_to_dofs,
    sDOF_to_coeffs)

    @assert Dc == 2 || Dc == 3
    @assert 0 ≤ Df < Dc

    num_vertices = GridapP4est.num_cell_vertices(Val{Dc})
    num_edges = GridapP4est.num_cell_edges(Val{Dc})
    num_faces = GridapP4est.num_cell_faces(Val{Dc})

    offset = 0
    if (Df ≥ 1)
        offset += num_vertices
        if (Df == 2)
            offset += num_edges
        end
    end

    cache_dof_ids = array_cache(cell_dof_ids)
    first_cache_cell_faces = array_cache(first(cell_faces))
    cache_cell_faces = Vector{typeof(first_cache_cell_faces)}(undef, length(cell_faces))
    for i = 1:length(cell_faces)
        cache_cell_faces[i] = array_cache(cell_faces[i])
    end

    for fid_hanging = 1:num_hanging_faces
        cell = hanging_faces_to_cell[fid_hanging]
        current_cell_dof_ids = getindex!(cache_dof_ids, cell_dof_ids, cell)
        lface = hanging_faces_to_lface[fid_hanging]
        ocell, ocell_lface, subface = hanging_faces_glue[fid_hanging]
        ocell_lface_within_dim = face_lid_within_dim(Val{Dc}, ocell_lface)
        oface_dim = face_dim(Val{Dc}, ocell_lface)

        if (Df == 0) # Am I a vertex?
            hanging_lvertex_within_first_subface = 2^oface_dim
            cur_subface_own_dofs = subface_own_dofs[oface_dim][hanging_lvertex_within_first_subface]
        elseif (Df == 1 && Dc == 3) # Am I an edge?
            if (subface < 0) # Edge hanging in the interior of a face 
                @assert subface == -1 || subface == -2 || subface == -3 || subface == -4
                @assert oface_dim == Dc - 1
                abs_subface = abs(subface)
                if (abs_subface == 1)
                    subface = 1
                    edge = 4 + 4 # num_vertices+edge_id
                elseif (abs_subface == 2)
                    subface = 3
                    edge = 4 + 4 # num_vertices+edge_id 
                elseif (abs_subface == 3)
                    subface = 3
                    edge = 4 + 1 # num_vertices+edge_id 
                elseif (abs_subface == 4)
                    subface = 4
                    edge = 4 + 1 # num_vertices+edge_id 
                end
                cur_subface_own_dofs = subface_own_dofs[oface_dim][edge]
            else
                @assert subface == 1 || subface == 2
                @assert oface_dim == 1
                hanging_lvertex_within_first_subface = 2^oface_dim
                cur_subface_own_dofs = subface_own_dofs[oface_dim][end]
            end
        elseif (Df == Dc - 1) # Am I a face?
            @assert oface_dim == Dc - 1
            cur_subface_own_dofs = subface_own_dofs[oface_dim][end]
        end


        oface = getindex!(cache_cell_faces[oface_dim+1], cell_faces[oface_dim+1], ocell)[ocell_lface_within_dim]
        oface_lid, _ = owner_faces_lids[oface_dim][oface]
        pindex = owner_faces_pindex[oface_dim][oface_lid]
        for ((ldof, dof), ldof_subface) in zip(enumerate(face_own_dofs[offset+lface]), cur_subface_own_dofs)
            push!(sDOF_to_dof, current_cell_dof_ids[dof])
            push!(sDOF_to_dofs, hanging_faces_owner_face_dofs[fid_hanging])
            coeffs = Vector{Float64}(undef, length(hanging_faces_owner_face_dofs[fid_hanging]))
            # Go over dofs of ocell_lface
            for (ifdof, icdof) in enumerate(face_dofs[ocell_lface])
                pifdof = node_permutations[oface_dim][pindex][ifdof]
                println("XXXX: $(ifdof) $(pifdof)")
                ldof_coarse = face_dofs[ocell_lface][pifdof]
                coeffs[ifdof] =
                    ref_constraints[face_subface_ldof_to_cell_ldof[oface_dim][ocell_lface_within_dim][subface][ldof_subface], ldof_coarse]
            end
            push!(sDOF_to_coeffs, coeffs)
        end
    end
end

# count how many different owner faces
# for each owner face 
#    track the global IDs of its face vertices from the perspective of the subfaces
# for each owner face 
#    compute permutation id
function _compute_owner_faces_pindex_and_lids(Df,
                                              Dc,
                                              num_hanging_faces,
                                              hanging_faces_glue,
                                              hanging_faces_to_cell,
                                              hanging_faces_to_lface,
                                              cell_vertices,
                                              cell_faces,
                                              lface_to_cvertices,
                                              pindex_to_cfvertex_to_fvertex)
    num_owner_faces = 0
    owner_faces_lids = Dict{Int,Tuple{Int,Int,Int}}()
    for fid_hanging = 1:num_hanging_faces
        ocell, ocell_lface, _ = hanging_faces_glue[fid_hanging]
        ocell_dim = face_dim(Val{Dc}, ocell_lface)
        if (ocell_dim == Df)
            ocell_lface_within_dim = face_lid_within_dim(Val{Dc}, ocell_lface)
            owner_face = cell_faces[ocell][ocell_lface_within_dim]
            if !(haskey(owner_faces_lids, owner_face))
                num_owner_faces += 1
                owner_faces_lids[owner_face] = (num_owner_faces, ocell, ocell_lface)
            end
        end
    end

    println("%%%: $(owner_faces_lids)")

    num_face_vertices = length(first(lface_to_cvertices))
    owner_face_vertex_ids = Vector{Int}(undef, num_face_vertices * num_owner_faces)
    owner_face_vertex_ids .= -1

    for fid_hanging = 1:num_hanging_faces
        ocell, ocell_lface, subface = hanging_faces_glue[fid_hanging]
        ocell_dim = face_dim(Val{Dc}, ocell_lface)
        if (ocell_dim == Df)
            cell = hanging_faces_to_cell[fid_hanging]
            lface = hanging_faces_to_lface[fid_hanging]
            cvertex = lface_to_cvertices[lface][subface]
            vertex = cell_vertices[cell][cvertex]
            ocell_lface_within_dim = face_lid_within_dim(Val{Dc}, ocell_lface)
            owner_face = cell_faces[ocell][ocell_lface_within_dim]
            owner_face_lid, _ = owner_faces_lids[owner_face]
            owner_face_vertex_ids[(owner_face_lid-1)*num_face_vertices+subface] = vertex
        end
    end

    println("???: $(owner_face_vertex_ids)")

    owner_faces_pindex = Vector{Int}(undef, num_owner_faces)
    for owner_face in keys(owner_faces_lids)
        (owner_face_lid, ocell, ocell_lface) = owner_faces_lids[owner_face]
        ocell_lface_within_dim = face_lid_within_dim(Val{Dc}, ocell_lface)
        # Compute permutation id by comparing 
        #  1. cell_vertices[ocell][ocell_lface]
        #  2. owner_face_vertex_ids 
        pindexfound = false
        cfvertex_to_cvertex = lface_to_cvertices[ocell_lface_within_dim]
        for (pindex, cfvertex_to_fvertex) in enumerate(pindex_to_cfvertex_to_fvertex)
            found = true
            for (cfvertex, fvertex) in enumerate(cfvertex_to_fvertex)
                vertex1 = owner_face_vertex_ids[(owner_face_lid-1)*num_face_vertices+fvertex]
                cvertex = cfvertex_to_cvertex[cfvertex]
                vertex2 = cell_vertices[ocell][cvertex]
                # -1 can only happen in the interface of two 
                # ghost cells at different refinement levels
                if (vertex1 != vertex2) && (vertex1 != -1) 
                    found = false
                    break
                end
            end
            if found
                owner_faces_pindex[owner_face_lid] = pindex
                pindexfound = true
                break
            end
        end
        @assert pindexfound "Valid pindex not found"
    end
    owner_faces_pindex, owner_faces_lids
end

function generate_constraints(dmodel::OctreeDistributedDiscreteModel{Dc},
    spaces_wo_constraints,
    reffe,
    ref_constraints,
    face_subface_ldof_to_cell_ldof) where {Dc}

    non_conforming_glue = dmodel.non_conforming_glue
    dmodel = dmodel.dmodel

    gridap_cell_faces = map(local_views(dmodel)) do model
        topo = Gridap.Geometry.get_grid_topology(model)
        Tuple(Gridap.Geometry.get_faces(topo, Dc, d) for d = 0:Dc-1)
    end
    num_regular_faces = map(non_conforming_glue) do ncglue
        println("regular= ", Tuple(ncglue.num_regular_faces[d] for d = 1:Dc))
        Tuple(ncglue.num_regular_faces[d] for d = 1:Dc)
    end
    num_hanging_faces = map(non_conforming_glue) do ncglue
        println("hanging= ", Tuple(ncglue.num_hanging_faces[d] for d = 1:Dc))
        Tuple(ncglue.num_hanging_faces[d] for d = 1:Dc)
    end
    hanging_faces_glue = map(non_conforming_glue) do ncglue
        Tuple(ncglue.hanging_faces_glue[d] for d = 1:Dc)
    end
    sDOF_to_dof, sDOF_to_dofs, sDOF_to_coeffs = map(gridap_cell_faces,
        num_regular_faces,
        num_hanging_faces,
        hanging_faces_glue,
        dmodel.models,
        spaces_wo_constraints) do gridap_cell_faces,
    num_regular_faces,
    num_hanging_faces,
    hanging_faces_glue,
    model,
    V

        hanging_faces_to_cell = Vector{Vector{Int}}(undef, Dc)
        hanging_faces_to_lface = Vector{Vector{Int}}(undef, Dc)

        # Locate for each hanging vertex a cell to which it belongs 
        # and local position within that cell 
        hanging_faces_to_cell[1],
        hanging_faces_to_lface[1] = _generate_hanging_faces_to_cell_and_lface(num_regular_faces[1],
            num_hanging_faces[1],
            gridap_cell_faces[1])

        if (Dc == 3)
            hanging_faces_to_cell[2],
            hanging_faces_to_lface[2] = _generate_hanging_faces_to_cell_and_lface(num_regular_faces[2],
                num_hanging_faces[2],
                gridap_cell_faces[2])
        end

        # Locate for each hanging facet a cell to which it belongs 
        # and local position within that cell 
        hanging_faces_to_cell[Dc],
        hanging_faces_to_lface[Dc] =
            _generate_hanging_faces_to_cell_and_lface(num_regular_faces[Dc],
                num_hanging_faces[Dc],
                gridap_cell_faces[Dc])

        basis, reffe_args, reffe_kwargs = reffe
        cell_reffe = ReferenceFE(Dc == 2 ? QUAD : HEX, basis, reffe_args...; reffe_kwargs...)
        reffe_cell = cell_reffe

        cell_dof_ids = get_cell_dof_ids(V)
        face_own_dofs = Gridap.ReferenceFEs.get_face_own_dofs(reffe_cell)
        face_dofs = Gridap.ReferenceFEs.get_face_dofs(reffe_cell)

        hanging_faces_owner_face_dofs = Vector{Vector{Vector{Int}}}(undef, Dc)

        hanging_faces_owner_face_dofs[1] = _generate_hanging_faces_owner_face_dofs(num_hanging_faces[1],
            face_dofs,
            hanging_faces_glue[1],
            cell_dof_ids)

        if (Dc == 3)
            hanging_faces_owner_face_dofs[2] = _generate_hanging_faces_owner_face_dofs(num_hanging_faces[2],
                face_dofs,
                hanging_faces_glue[2],
                cell_dof_ids)
        end

        hanging_faces_owner_face_dofs[Dc] = _generate_hanging_faces_owner_face_dofs(num_hanging_faces[Dc],
            face_dofs,
            hanging_faces_glue[Dc],
            cell_dof_ids)

        sDOF_to_dof = Int[]
        sDOF_to_dofs = Vector{Int}[]
        sDOF_to_coeffs = Vector{Float64}[]

        facet_polytope = Dc == 2 ? SEGMENT : QUAD
        if (Dc == 3)
            edget_polytope = SEGMENT
        end

        basis, reffe_args, reffe_kwargs = reffe
        face_reffe = ReferenceFE(facet_polytope, basis, reffe_args...; reffe_kwargs...)
        pindex_to_cfvertex_to_fvertex = Gridap.ReferenceFEs.get_vertex_permutations(facet_polytope)

        if (Dc == 3)
            edge_reffe = ReferenceFE(edget_polytope, basis, reffe_args...; reffe_kwargs...)
            pindex_to_cevertex_to_evertex = Gridap.ReferenceFEs.get_vertex_permutations(edget_polytope)
        end

        owner_faces_pindex = Vector{Vector{Int}}(undef, Dc - 1)
        owner_faces_lids = Vector{Dict{Int,Tuple{Int,Int,Int}}}(undef, Dc - 1)

        lface_to_cvertices = Gridap.ReferenceFEs.get_faces(Dc == 2 ? QUAD : HEX, Dc - 1, 0)
        owner_faces_pindex[Dc-1], owner_faces_lids[Dc-1] = _compute_owner_faces_pindex_and_lids(Dc - 1, Dc,
            num_hanging_faces[Dc],
            hanging_faces_glue[Dc],
            hanging_faces_to_cell[Dc],
            hanging_faces_to_lface[Dc],
            gridap_cell_faces[1],
            gridap_cell_faces[Dc],
            lface_to_cvertices,
            pindex_to_cfvertex_to_fvertex)

        if (Dc == 3)
            ledge_to_cvertices = Gridap.ReferenceFEs.get_faces(HEX, 1, 0)
            pindex_to_cevertex_to_evertex = Gridap.ReferenceFEs.get_vertex_permutations(SEGMENT)
            owner_faces_pindex[1], owner_faces_lids[1] = _compute_owner_faces_pindex_and_lids(1, Dc,
                num_hanging_faces[2],
                hanging_faces_glue[2],
                hanging_faces_to_cell[2],
                hanging_faces_to_lface[2],
                gridap_cell_faces[1],
                gridap_cell_faces[2],
                ledge_to_cvertices,
                pindex_to_cevertex_to_evertex)
        end


        node_permutations = Vector{Vector{Vector{Int}}}(undef, Dc - 1)
        nodes, _ = Gridap.ReferenceFEs.compute_nodes(facet_polytope, [reffe_args[2] for i = 1:Dc-1])
        node_permutations[Dc-1] = Gridap.ReferenceFEs._compute_node_permutations(facet_polytope, nodes)
        if (Dc == 3)
            nodes, _ = Gridap.ReferenceFEs.compute_nodes(edget_polytope, [reffe_args[2] for i = 1:Dc-2])
            node_permutations[1] = Gridap.ReferenceFEs._compute_node_permutations(edget_polytope, nodes)
        end

        subface_own_dofs = Vector{Vector{Vector{Int}}}(undef, Dc - 1)
        subface_own_dofs[Dc-1] = Gridap.ReferenceFEs.get_face_own_dofs(face_reffe)
        if (Dc == 3)
            subface_own_dofs[1] = Gridap.ReferenceFEs.get_face_own_dofs(edge_reffe)
        end
        _generate_constraints!(0,
            Dc,
            [gridap_cell_faces[i] for i = 1:Dc],
            num_hanging_faces[1],
            hanging_faces_to_cell[1],
            hanging_faces_to_lface[1],
            hanging_faces_owner_face_dofs[1],
            hanging_faces_glue[1],
            face_subface_ldof_to_cell_ldof,
            face_dofs,
            face_own_dofs,
            subface_own_dofs,
            cell_dof_ids,
            node_permutations,
            owner_faces_pindex,
            owner_faces_lids,
            ref_constraints,
            sDOF_to_dof,
            sDOF_to_dofs,
            sDOF_to_coeffs)

        if (Dc == 3)
            _generate_constraints!(1,
                Dc,
                [gridap_cell_faces[i] for i = 1:Dc],
                num_hanging_faces[2],
                hanging_faces_to_cell[2],
                hanging_faces_to_lface[2],
                hanging_faces_owner_face_dofs[2],
                hanging_faces_glue[2],
                face_subface_ldof_to_cell_ldof,
                face_dofs,
                face_own_dofs,
                subface_own_dofs,
                cell_dof_ids,
                node_permutations,
                owner_faces_pindex,
                owner_faces_lids,
                ref_constraints,
                sDOF_to_dof,
                sDOF_to_dofs,
                sDOF_to_coeffs)
        end
        _generate_constraints!(Dc - 1,
            Dc,
            [gridap_cell_faces[i] for i = 1:Dc],
            num_hanging_faces[Dc],
            hanging_faces_to_cell[Dc],
            hanging_faces_to_lface[Dc],
            hanging_faces_owner_face_dofs[Dc],
            hanging_faces_glue[Dc],
            face_subface_ldof_to_cell_ldof,
            face_dofs,
            face_own_dofs,
            subface_own_dofs,
            cell_dof_ids,
            node_permutations,
            owner_faces_pindex,
            owner_faces_lids,
            ref_constraints,
            sDOF_to_dof,
            sDOF_to_dofs,
            sDOF_to_coeffs)
        sDOF_to_dof, Gridap.Arrays.Table(sDOF_to_dofs), Gridap.Arrays.Table(sDOF_to_coeffs)
    end |> tuple_of_arrays
end

# An auxiliary function which we use in order to generate a version of  
# get_cell_dof_ids() for FE spaces with linear constraints which is suitable 
# for the algorithm which generates the global DoFs identifiers
function fe_space_with_linear_constraints_cell_dof_ids(Uc::FESpaceWithLinearConstraints)
    U_cell_dof_ids = Gridap.Arrays.Table(get_cell_dof_ids(Uc.space))
    ndata = U_cell_dof_ids.ptrs[end] - 1
    Uc_cell_dof_ids_data = zeros(eltype(U_cell_dof_ids.data), ndata)
    max_negative_minus_one = -maximum(-U_cell_dof_ids.data) - 1
    # max_negative_minus_one can only be zero whenever there are no 
    # negative values in U_cell_dof_ids.data (i.e., no Dirichlet DoFs)
    if (max_negative_minus_one==0) 
        max_negative_minus_one = -1
    end 
    n_cells = length(U_cell_dof_ids)
    n_fdofs = num_free_dofs(Uc.space)
    n_fmdofs = Uc.n_fmdofs
    for cell in 1:n_cells
        pini = U_cell_dof_ids.ptrs[cell]
        pend = U_cell_dof_ids.ptrs[cell+1] - 1
        for p in pini:pend
            dof = U_cell_dof_ids.data[p]
            DOF = Gridap.FESpaces._dof_to_DOF(dof, n_fdofs)
            qini = Uc.DOF_to_mDOFs.ptrs[DOF]
            qend = Uc.DOF_to_mDOFs.ptrs[DOF+1] - 1
            if (qend - qini == 0) # master DOF 
                mDOF = Uc.DOF_to_mDOFs.data[qini]
                mdof = Gridap.FESpaces._DOF_to_dof(mDOF, n_fmdofs)
                Uc_cell_dof_ids_data[p] = mdof
            else # slave DoF
                @assert qend - qini > 0
                Uc_cell_dof_ids_data[p] = max_negative_minus_one
            end
        end
    end
    Gridap.Arrays.Table(Uc_cell_dof_ids_data, U_cell_dof_ids.ptrs)
end

# Generates a new DistributedSingleFieldFESpace composed 
# by local FE spaces with linear multipoint constraints added
function Gridap.FESpaces.FESpace(model::OctreeDistributedDiscreteModel{Dc}, reffe; kwargs...) where {Dc}
    order = reffe[2][2]
    spaces_wo_constraints = map(local_views(model)) do m
        FESpace(m, reffe; kwargs...)
    end
    ref_constraints = _build_constraint_coefficients_matrix_in_ref_space(Dc, reffe)
    cell_polytope = Dc == 2 ? QUAD : HEX
    rr = Gridap.Adaptivity.RedRefinementRule(cell_polytope)
    face_subface_ldof_to_cell_ldof = Vector{Vector{Vector{Vector{Int32}}}}(undef, Dc - 1)
    face_subface_ldof_to_cell_ldof[Dc-1] =
        Gridap.Adaptivity.get_face_subface_ldof_to_cell_ldof(rr, Tuple(order for _ = 1:Dc), Dc - 1)
    if (Dc == 3)
        face_subface_ldof_to_cell_ldof[1] =
            Gridap.Adaptivity.get_face_subface_ldof_to_cell_ldof(rr, Tuple(order for _ = 1:Dc), 1)
    end
    sDOF_to_dof, sDOF_to_dofs, sDOF_to_coeffs =
        generate_constraints(model, spaces_wo_constraints, reffe, ref_constraints, face_subface_ldof_to_cell_ldof)

    spaces_w_constraints = map(spaces_wo_constraints,
        sDOF_to_dof,
        sDOF_to_dofs,
        sDOF_to_coeffs) do V, sDOF_to_dof, sDOF_to_dofs, sDOF_to_coeffs
        Vc = FESpaceWithLinearConstraints(sDOF_to_dof, sDOF_to_dofs, sDOF_to_coeffs, V)
    end

    local_cell_dof_ids = map(spaces_w_constraints) do Vc
        result = fe_space_with_linear_constraints_cell_dof_ids(Vc)
        println("result=", result)
        result
    end
    nldofs = map(num_free_dofs,spaces_w_constraints)
    cell_gids = get_cell_gids(model)
    gids=GridapDistributed.generate_gids(cell_gids,local_cell_dof_ids,nldofs)
    vector_type = GridapDistributed._find_vector_type(spaces_w_constraints,gids)
    GridapDistributed.DistributedSingleFieldFESpace(spaces_w_constraints,gids,vector_type)
end