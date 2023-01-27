using P4est_wrapper
using GridapP4est
using Gridap
using PartitionedArrays
using MPI

# Generate a local numbering of vertices that includes hanging vertices 
# Generate a local numbering of faces out of the one generated by vertices (automatic? to confirm)

# Establish the correspondence among local numbering of vertices and p4est global numbering 
# Establish the correspondence among local numbering of faces and p4est global numbering 

# Generate a global numbering of (regular,hanging) vertices?
# Generate a global numbering of (regular,hanging) faces?


## Better to use a C-enum. But I did not use it in order to keep the Julia
## version of this C example as simple as possible
const nothing_flag = Cint(0)
const refine_flag  = Cint(1)

## Refine those cells with even identifier    (0,2,4,6,8,...)
## Leave untouched cells with odd identifier  (1,3,5,7,9,...)
function allocate_and_set_refinement_and_coarsening_flags(forest_ptr::Ptr{p4est_t})
  forest = forest_ptr[]
  tree = p4est_tree_array_index(forest.trees, 0)[]
  return [i != 1 ? nothing_flag : refine_flag for i = 1:tree.quadrants.elem_count]
end

const p4est_corner_faces         = [0 2; 1 2; 0 3; 1 3]
const p4est_corner_face_corners  = [0  -1 0 -1; -1 0 1 -1; 1 -1 -1  0; -1 1 -1 1]
const p4est_face_corners         = [0 2; 1 3; 0 1; 2 3]
const num_cell_vertices          = 4
const num_cell_faces             = 4 
const hanging_vertex_code        = -2 

# To add to P4est_wrapper.jl library
# I just translated this function to Julia from its p4est counterpart
# We cannot call it directly because it is declared as static within p4est,
# and thus it does not belong to the ABI of the dynamic library object.

# /** Decode the face_code into hanging face information.
#  *
#  * This is mostly for demonstration purposes.  Applications probably will
#  * integrate it into their own loop over the face for performance reasons.
#  *
#  * \param[in] face_code as in the p4est_lnodes_t structure.
#  * \param[out] hanging face: if there are hanging faces,
#  *             hanging_face = -1 if the face is not hanging,
#  *                          = 0 if the face is the first half,
#  *                          = 1 if the face is the second half.
#  *             note: not touched if there are no hanging faces.
#  * \return              true if any face is hanging, false otherwise.
#  */

function p4est_lnodes_decode(face_code, hanging_face)
  @assert face_code>=0
  if (face_code!=0)
    c = face_code & 0x03
    work = face_code >> 2
    hanging_face .= -1
    for i=0:1
      f = p4est_corner_faces[c+1,i+1]
      hanging_face[f+1] = (work & 0x01)!=0 ? p4est_corner_face_corners[c+1,f+1] : -1
      work >>= 1
    end
    return 1
  else
    return 0
  end
end

## Global variable which is updated across calls to init_fn_callback_2d
current_quadrant_index = Cint(0)
## Global variable which is updated across calls to refine_replace_callback_2d
num_calls = Cint(0)

# This C callback function is called once per quadtree quadrant. Here we are assuming
# that p4est->user_pointer has been set prior to the first call to this call
# back function to an array of ints with as many entries as forest quadrants. This call back function
# initializes the quadrant->p.user_data void * pointer of all quadrants such that it
# points to the corresponding entry in the global array mentioned in the previous sentence.
function init_fn_callback_2d(forest_ptr::Ptr{p4est_t},
                            which_tree::p4est_topidx_t,
                            quadrant_ptr::Ptr{p4est_quadrant_t})
    @assert which_tree == 0
    # Extract a reference to the first (and uniquely allowed) tree
    forest = forest_ptr[]
    tree = p4est_tree_array_index(forest.trees, 0)[]
    quadrant = quadrant_ptr[]
    q = P4est_wrapper.p4est_quadrant_array_index(tree.quadrants, current_quadrant_index)
    @assert p4est_quadrant_compare(q,quadrant_ptr) == 0
    user_data  = unsafe_wrap(Array, Ptr{Cint}(forest.user_pointer), current_quadrant_index+1)[current_quadrant_index+1]
    unsafe_store!(Ptr{Cint}(quadrant.p.user_data), user_data, 1)
    global current_quadrant_index = (current_quadrant_index+1) % (tree.quadrants.elem_count)
    return nothing
end

const init_fn_callback_2d_c = @cfunction(init_fn_callback_2d, Cvoid, (Ptr{p4est_t}, p4est_topidx_t, Ptr{p4est_quadrant_t}))


function refine_callback_2d(::Ptr{p4est_t},
                            which_tree::p4est_topidx_t,
                            quadrant_ptr::Ptr{p4est_quadrant_t})
    @assert which_tree == 0
    quadrant = quadrant_ptr[]
    return Cint(unsafe_wrap(Array, Ptr{Cint}(quadrant.p.user_data),1)[] == refine_flag)
end

const refine_callback_2d_c = @cfunction(refine_callback_2d, Cint, (Ptr{p4est_t}, p4est_topidx_t, Ptr{p4est_quadrant_t}))


# In the local scope of this function, the term "face"
# should be understood as a generic d-face, i.e., 
# either a vertex, edge, face, etc. 
function process_current_face!(gridap_cell_faces,
                               regular_face_p4est_to_gridap,
                               num_regular_faces,
                               p4est_faces,
                               p4est_lface,
                               p4est_gface,
                               p4est_lface_to_gridap_lface)  
  
  if !(haskey(regular_face_p4est_to_gridap,p4est_gface))
    num_regular_faces+=1
    regular_face_p4est_to_gridap[p4est_gface]=num_regular_faces
  end
  gridap_cell_faces[p4est_lface_to_gridap_lface[p4est_lface]]=
       regular_face_p4est_to_gridap[p4est_gface]
  return num_regular_faces
end 

# TO-DO: refine and coarsening flags should be an input argument, instead of being hard-coded
function adapt_non_conforming_work_in_progress(model::OctreeDistributedDiscreteModel{Dc,Dp}) where {Dc,Dp}
    # Copy and refine input p4est
    ptr_new_pXest = GridapP4est.pXest_copy(Val{Dc}, model.ptr_pXest)

    user_data = allocate_and_set_refinement_and_coarsening_flags(ptr_new_pXest)
    p4est_reset_data(ptr_new_pXest, Cint(sizeof(Cint)), init_fn_callback_2d_c, pointer(user_data))
    p4est_refine_ext(ptr_new_pXest, 0, -1, refine_callback_2d_c, C_NULL, C_NULL)
    p4est_partition(ptr_new_pXest, 1, C_NULL)

    p4est_vtk_write_file(ptr_new_pXest, C_NULL, string("adapted_forest"))

    ptr_pXest_ghost = GridapP4est.setup_pXest_ghost(Val{Dc}, ptr_new_pXest)
    pXest_lnodes    = GridapP4est.p4est_lnodes_new(ptr_new_pXest, ptr_pXest_ghost, -2)
    lnodes          = pXest_lnodes[]
    element_nodes   = unsafe_wrap(Array, lnodes.element_nodes, lnodes.vnodes*lnodes.num_local_elements)
    face_code       = unsafe_wrap(Array, lnodes.face_code, lnodes.num_local_elements)
    hanging_face    = Vector{Cint}(undef,4)

    # Count regular vertices
    num_regular_vertices=0
    regular_vertices_p4est_to_gridap=Dict{Int,Int}()

    num_regular_faces=0
    regular_faces_p4est_to_gridap=Dict{Int,Int}()


    # Build a map from faces to (cell,lface)
    p4est_gface_to_gcell_p4est_lface=Dict{Int,Tuple{Int,Int}}()
    for cell=1:lnodes.num_local_elements
      start = (cell-1)*lnodes.vnodes+1
      p4est_cell_faces = view(element_nodes, start:start+3)
      for (lface,gface) in enumerate(p4est_cell_faces)
        p4est_gface_to_gcell_p4est_lface[gface]=(cell,lface)
      end 
    end

    hanging_vertices_pairs_to_owner_face=Dict{Tuple{Int,Int},Int}()
    hanging_faces_pairs_to_owner_face=Dict{Tuple{Int,Int},Int}()


    P4EST_2_GRIDAP_VERTEX_2D=Gridap.Arrays.IdentityVector(num_cell_vertices)

    gridap_cells_vertices=Vector{Int}(undef, lnodes.num_local_elements*4)
    gridap_cells_vertices .= -1

    gridap_cells_faces=Vector{Int}(undef, lnodes.num_local_elements*4)
    gridap_cells_faces .= -1

    for cell=1:lnodes.num_local_elements
      start                 = (cell-1)*lnodes.vnodes+1
      start_gridap_vertices = (cell-1)*num_cell_vertices
      start_gridap_faces    = (cell-1)*num_cell_faces
      p4est_cell_faces      = view(element_nodes, start:start+3)
      p4est_cell_vertices   = view(element_nodes, start+4:start+7)


      gridap_cell_vertices = view(gridap_cells_vertices, 
                                  start_gridap_vertices+1:start_gridap_vertices+num_cell_vertices)
      gridap_cell_faces    = view(gridap_cells_faces, 
                                  start_gridap_faces+1:start_gridap_faces+num_cell_faces)
      has_hanging          = p4est_lnodes_decode(face_code[cell], hanging_face)
      if has_hanging==0
        # All vertices/faces of the current cell are regular 
        # Process vertices
        for (p4est_lvertex,p4est_gvertex) in enumerate(p4est_cell_vertices)
          num_regular_vertices=
             process_current_face!(gridap_cell_vertices,
                                   regular_vertices_p4est_to_gridap,
                                   num_regular_vertices,
                                   p4est_cell_vertices,
                                   p4est_lvertex,
                                   p4est_gvertex,
                                   P4EST_2_GRIDAP_VERTEX_2D)  
        end
        # Process faces
        for (p4est_lface,p4est_gface) in enumerate(p4est_cell_faces)
          num_regular_faces=
             process_current_face!(gridap_cell_faces,
                                   regular_faces_p4est_to_gridap,
                                   num_regular_faces,
                                   p4est_cell_faces,
                                   p4est_lface,
                                   p4est_gface,
                                   GridapP4est.P4EST_2_GRIDAP_FACET_2D)
        end
      else 
         # "Touch" hanging vertices before processing current cell
         # This is required as we dont have any means to detect 
         # a hanging vertex from a non-hanging face
         for (p4est_lface,half) in enumerate(hanging_face)
           if (half != -1)
              hanging_vertex_lvertex_within_face = half == 0 ? 1 : 0
              p4est_lvertex=p4est_face_corners[p4est_lface,
                                               hanging_vertex_lvertex_within_face+1]
              gridap_cell_vertices[P4EST_2_GRIDAP_VERTEX_2D[p4est_lvertex+1]]=hanging_vertex_code
           end 
         end

        # Current cell has at least one hanging face 
        for (p4est_lface,half) in enumerate(hanging_face)
          # Current face is NOT hanging
          if (half==-1)
            # Process vertices on the boundary of p4est_lface
            for p4est_lvertex in p4est_face_corners[p4est_lface,:]
              p4est_gvertex=p4est_cell_vertices[p4est_lvertex+1]
              if (gridap_cell_vertices[p4est_lvertex+1] != hanging_vertex_code)
                num_regular_vertices=
                    process_current_face!(gridap_cell_vertices,
                                          regular_vertices_p4est_to_gridap,
                                          num_regular_vertices,
                                          p4est_cell_vertices,
                                          p4est_lvertex+1,
                                          p4est_gvertex,
                                          P4EST_2_GRIDAP_VERTEX_2D)
              end
            end
            # Process non-hanging face
            p4est_gface=p4est_cell_faces[p4est_lface]
            num_regular_faces=
                process_current_face!(gridap_cell_faces,
                                      regular_faces_p4est_to_gridap,
                                      num_regular_faces,
                                      p4est_cell_faces,
                                      p4est_lface,
                                      p4est_gface,
                                      GridapP4est.P4EST_2_GRIDAP_FACET_2D)
          else # Current face is hanging
            
            # Identify regular vertex and hanging vertex 
            # Repeat code above for regular vertex 
            # Special treatment for hanging vertex 
            regular_vertex_lvertex_within_face = half == 0 ? 0 : 1 
            hanging_vertex_lvertex_within_face = half == 0 ? 1 : 0
            
            # Process regular vertex
            p4est_regular_lvertex = p4est_face_corners[p4est_lface,regular_vertex_lvertex_within_face+1]
            p4est_gvertex=p4est_cell_vertices[p4est_regular_lvertex+1]
            num_regular_vertices=
                process_current_face!(gridap_cell_vertices,
                                      regular_vertices_p4est_to_gridap,
                                      num_regular_vertices,
                                      p4est_cell_vertices,
                                      p4est_regular_lvertex+1,
                                      p4est_gvertex,
                                      P4EST_2_GRIDAP_VERTEX_2D)
            # Process hanging vertex
            p4est_hanging_lvertex = p4est_face_corners[p4est_lface,hanging_vertex_lvertex_within_face+1]
            owner_face            = p4est_cell_faces[p4est_lface]
            hanging_vertices_pairs_to_owner_face[(cell,P4EST_2_GRIDAP_VERTEX_2D[p4est_hanging_lvertex+1])]=owner_face
            # if !(haskey(owner_faces_touched,owner_face))
            #   num_face_owners += 1
            #   owner_faces_touched[owner_face]=num_face_owners
            # end

            # Process hanging face
            hanging_faces_pairs_to_owner_face[(cell,GridapP4est.P4EST_2_GRIDAP_FACET_2D[p4est_lface])]=owner_face
          end
        end
      end
    end

    # Go over all touched hanging faces and start 
    # assigning IDs from the last num_regular_faces ID
    # For each hanging face, keep track of (owner_cell,lface)
    hanging_faces_owner_cell_and_lface=
        Vector{Tuple{Int,Int}}(undef,length(keys(hanging_faces_pairs_to_owner_face)))
    num_hanging_faces = 0
    for key in keys(hanging_faces_pairs_to_owner_face)
      (cell,lface)=key
      owner_p4est_gface=hanging_faces_pairs_to_owner_face[key]
      owner_gridap_gface=regular_faces_p4est_to_gridap[owner_p4est_gface]
      num_hanging_faces+=1
      start_gridap_faces = (cell-1)*num_cell_faces
      gridap_cells_faces[start_gridap_faces+lface]=num_regular_faces+num_hanging_faces
      (owner_cell,p4est_lface)=p4est_gface_to_gcell_p4est_lface[owner_p4est_gface]
      hanging_faces_owner_cell_and_lface[num_hanging_faces]=
         (owner_cell,GridapP4est.P4EST_2_GRIDAP_FACET_2D[p4est_lface])
    end   


    # Go over all touched hanging vertices and start 
    # assigning IDs from the last num_regular_vertices ID
    # For each hanging face, keep track of (owner_cell,lface)
    num_hanging_vertices = 0 
    hanging_vertices_owner_cell_and_lface=Tuple{Int,Int}[]
    owner_gridap_gface_to_hanging_vertex=Dict{Int,Int}()
    for key in keys(hanging_vertices_pairs_to_owner_face)
       (cell,lvertex)=key
       owner_p4est_gface=hanging_vertices_pairs_to_owner_face[key]
       owner_gridap_gface=regular_faces_p4est_to_gridap[owner_p4est_gface]
       if !(haskey(owner_gridap_gface_to_hanging_vertex,owner_gridap_gface))
        num_hanging_vertices+=1
        owner_gridap_gface_to_hanging_vertex[owner_gridap_gface]=num_hanging_vertices
        (owner_cell,p4est_lface)=p4est_gface_to_gcell_p4est_lface[owner_p4est_gface]
        push!(hanging_vertices_owner_cell_and_lface,
              (owner_cell,GridapP4est.P4EST_2_GRIDAP_FACET_2D[p4est_lface]))
       end 
       start_gridap_vertices = (cell-1)*num_cell_vertices
       gridap_cells_vertices[start_gridap_vertices+lvertex]=num_regular_vertices+
                                                            owner_gridap_gface_to_hanging_vertex[owner_gridap_gface]
    end

    println("#### vertices ###")
    println("num_regular_vertices: $(num_regular_vertices)")
    println("num_hanging_vertices: $(num_hanging_vertices)")
    println("gridap_cells_vertices: $(gridap_cells_vertices)")
    println(hanging_vertices_pairs_to_owner_face)
    println(hanging_vertices_owner_cell_and_lface)


    println("### faces ###")
    println("num_regular_faces: $(num_regular_faces)")
    println("num_hanging_faces: $(num_hanging_faces)")
    println("gridap_cells_faces: $(gridap_cells_faces)")
    println(hanging_faces_pairs_to_owner_face)
    println(hanging_faces_owner_cell_and_lface)

    # old_comm = model.parts.comm
    # if (i_am_in(old_comm))
    #   # Copy and refine input p4est
    #   ptr_new_pXest = pXest_copy(Val{Dc}, model.ptr_pXest)
    #   pXest_refine!(Val{Dc}, ptr_new_pXest)
    # else
    #   ptr_new_pXest = nothing
    # end
 
    # new_comm = isa(parts,Nothing) ? old_comm : parts.comm
    # if i_am_in(new_comm)
    #    if !isa(parts,Nothing)
    #      aux = ptr_new_pXest
    #      ptr_new_pXest = _p4est_to_new_comm(ptr_new_pXest,
    #                                         model.ptr_pXest_connectivity,
    #                                         model.parts.comm,
    #                                         parts.comm)
    #      if i_am_in(old_comm)
    #        pXest_destroy(Val{Dc},aux)
    #      end
    #    end
 
    #    # Extract ghost and lnodes
    #    ptr_pXest_ghost  = setup_pXest_ghost(Val{Dc}, ptr_new_pXest)
    #    ptr_pXest_lnodes = setup_pXest_lnodes(Val{Dc}, ptr_new_pXest, ptr_pXest_ghost)
 
    #    # Build fine-grid mesh
    #    new_parts = isa(parts,Nothing) ? model.parts : parts
    #    fmodel = setup_distributed_discrete_model(Val{Dc},
    #                                            new_parts,
    #                                            model.coarse_model,
    #                                            model.ptr_pXest_connectivity,
    #                                            ptr_new_pXest,
    #                                            ptr_pXest_ghost,
    #                                            ptr_pXest_lnodes)
 
    #    pXest_lnodes_destroy(Val{Dc},ptr_pXest_lnodes)
    #    pXest_ghost_destroy(Val{Dc},ptr_pXest_ghost)
 
    #    dglue = _compute_fine_to_coarse_model_glue(model.parts,
    #                                               model.dmodel,
    #                                               fmodel)
 
    #    ref_model = OctreeDistributedDiscreteModel(Dc,Dp,
    #                                   new_parts,
    #                                   fmodel,
    #                                   model.coarse_model,
    #                                   model.ptr_pXest_connectivity,
    #                                   ptr_new_pXest,
    #                                   false,
    #                                   model)
    #    return ref_model, dglue
    # else
    #  new_parts = isa(parts,Nothing) ? model.parts : parts
    #  return VoidOctreeDistributedDiscreteModel(model,new_parts), nothing
    # end
 end

 function run(parts,subdomains)
   #GridapP4est.with(parts) do
     if length(subdomains) == 2
       domain=(0,1,0,1)
     else
       @assert length(subdomains) == 3
       domain=(0,1,0,1,0,1)
     end
     # Generate model 
     coarse_model = CartesianDiscreteModel(domain, subdomains)
     model = OctreeDistributedDiscreteModel(parts, coarse_model, 1)
     adapt_non_conforming_work_in_progress(model) 
   #end
end

MPI.Init()
parts = get_part_ids(MPIBackend(),1)
run(parts,(1,1))
MPI.Finalize()






