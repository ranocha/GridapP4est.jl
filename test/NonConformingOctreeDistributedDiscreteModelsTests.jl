module NonConformingOctreeDistributedDiscreteModelsTests
  using P4est_wrapper
  using GridapP4est
  using Gridap
  using PartitionedArrays
  using GridapDistributed
  using MPI
  using Gridap.FESpaces
  using FillArrays
  # Generate a local numbering of vertices that includes hanging vertices 
  # Generate a local numbering of faces out of the one generated by vertices (automatic? to confirm)

  # Establish the correspondence among local numbering of vertices and p4est global numbering 
  # Establish the correspondence among local numbering of faces and p4est global numbering 

  # Generate a global numbering of (regular,hanging) vertices?
  # Generate a global numbering of (regular,hanging) faces?

  function setup_model(::Type{Val{3}}, perm)
  #               5 +--------+ 7 
  #                /        /|
  #               /        / |
  #            6 +--------+  |
  #              |        |  |
  #              |  1     |  + 3 
  #              |        | /
  #              |        |/
  #            2 +--------+ 4

  #     6  +--------+ 8 
  #       /        /|
  #      /        / |
  #  11 +--------+  |
  #     |        |  |
  #     |  2     |  + 4
  #     |        | /
  #     |        |/
  #   9 +--------+ 10
    ptr  = [ 1, 9, 17 ]
    if (perm==1)
      data = [ 1,2,3,4,5,6,7,8, 2,9,4,10,6,11,8,12 ]
    elseif (perm==2)
      data = [ 1,2,3,4,5,6,7,8, 10,12,4,8,9,11,2,6 ]
    elseif (perm==3)
      data = [ 1,2,3,4,5,6,7,8, 12,11,8,6,10,9,4,2 ]
    elseif (perm==4) 
      data = [ 1,2,3,4,5,6,7,8, 11,9,6,2,12,10,8,4 ]
    end  
    cell_vertex_lids = Gridap.Arrays.Table(data,ptr)
    node_coordinates = Vector{Point{3,Float64}}(undef,12)
    node_coordinates[1]=Point{3,Float64}(0.0,0.0,0.0)
    node_coordinates[2]=Point{3,Float64}(1.0,0.0,0.0)
    node_coordinates[3]=Point{3,Float64}(0.0,1.0,0.0)
    node_coordinates[4]=Point{3,Float64}(1.0,1.0,0.0)
    node_coordinates[5]=Point{3,Float64}(0.0,0.0,1.0)
    node_coordinates[6]=Point{3,Float64}(1.0,0.0,1.0)
    node_coordinates[7]=Point{3,Float64}(0.0,1.0,1.0)
    node_coordinates[8]=Point{3,Float64}(1.0,1.0,1.0)
    node_coordinates[9]=Point{3,Float64}(2.0,0.0,0.0)
    node_coordinates[10]=Point{3,Float64}(2.0,1.0,0.0)
    node_coordinates[11]=Point{3,Float64}(2.0,0.0,1.0)
    node_coordinates[12]=Point{3,Float64}(2.0,1.0,1.0)

    polytope=HEX
    scalar_reffe=Gridap.ReferenceFEs.ReferenceFE(polytope,Gridap.ReferenceFEs.lagrangian,Float64,1)
    cell_types=collect(Fill(1,length(cell_vertex_lids)))
    cell_reffes=[scalar_reffe]
    grid = Gridap.Geometry.UnstructuredGrid(node_coordinates,
                                            cell_vertex_lids,
                                            cell_reffes,
                                            cell_types,
                                            Gridap.Geometry.NonOriented())
    m=Gridap.Geometry.UnstructuredDiscreteModel(grid)
    labels = get_face_labeling(m)
    labels.d_to_dface_to_entity[1].=2
    if (perm==1 || perm==2)
      labels.d_to_dface_to_entity[2].=2
      labels.d_to_dface_to_entity[3].=[2,2,2,2,2,1,2,2,2,2,2]
    elseif (perm==3 || perm==4)
      labels.d_to_dface_to_entity[2].=2
      labels.d_to_dface_to_entity[3].=[2,2,2,2,2,1,2,2,2,2,2]
    end
    labels.d_to_dface_to_entity[4].=1  
    add_tag!(labels,"boundary",[2])
    add_tag!(labels,"interior",[1])
    m
  end

  function setup_model(::Type{Val{2}}, perm)
    @assert perm ∈ (1,2,3,4)
    #
    #  3-------4-------6
    #  |       |       |
    #  |       |       |
    #  |       |       |
    #  1-------2-------5
    #
        ptr  = [ 1, 5, 9 ]
        if (perm==1)
          data = [ 1,2,3,4, 2,5,4,6 ]
        elseif (perm==2)
          data = [ 1,2,3,4, 6,4,5,2 ]
        elseif (perm==3)
          data = [ 4,3,2,1, 2,5,4,6 ]
        elseif (perm==4) 
          data = [ 4,3,2,1, 6,4,5,2 ]
        end  
        cell_vertex_lids = Gridap.Arrays.Table(data,ptr)
        node_coordinates = Vector{Point{2,Float64}}(undef,6)
        node_coordinates[1]=Point{2,Float64}(0.0,0.0)
        node_coordinates[2]=Point{2,Float64}(1.0,0.0)
        node_coordinates[3]=Point{2,Float64}(0.0,1.0)
        node_coordinates[4]=Point{2,Float64}(1.0,1.0)
        node_coordinates[5]=Point{2,Float64}(2.0,0.0)
        node_coordinates[6]=Point{2,Float64}(2.0,1.0)
    
        polytope=QUAD
        scalar_reffe=Gridap.ReferenceFEs.ReferenceFE(polytope,Gridap.ReferenceFEs.lagrangian,Float64,1)
        cell_types=collect(Fill(1,length(cell_vertex_lids)))
        cell_reffes=[scalar_reffe]
        grid = Gridap.Geometry.UnstructuredGrid(node_coordinates,
                                                cell_vertex_lids,
                                                cell_reffes,
                                                cell_types,
                                                Gridap.Geometry.NonOriented())
        m=Gridap.Geometry.UnstructuredDiscreteModel(grid)
        labels = get_face_labeling(m)
        labels.d_to_dface_to_entity[1].=2
        if (perm==1 || perm==2)
          labels.d_to_dface_to_entity[2].=[2,2,2,1,2,2,2]
        elseif (perm==3 || perm==4)
          labels.d_to_dface_to_entity[2].=[2,2,1,2,2,2,2] 
        end
        labels.d_to_dface_to_entity[3].=1
        add_tag!(labels,"boundary",[2])
        add_tag!(labels,"interior",[1])
        m
  end


  function test(ranks,TVDc::Type{Val{Dc}}, perm, order) where Dc

    function test_solve(dmodel,order)
      # Define manufactured functions
      u(x) = x[1]+x[2]^order
      f(x) = -Δ(u)(x)

      # FE Spaces
      reffe = ReferenceFE(lagrangian,Float64,order)
      V = TestFESpace(dmodel,reffe,dirichlet_tags="boundary")
      U = TrialFESpace(V,u)

      # Define integration mesh and quadrature
      degree = 2*order+1
      Ω = Triangulation(dmodel)
      dΩ = Measure(Ω,degree)

      a(u,v) = ∫( ∇(v)⊙∇(u) )*dΩ
      b(v) = ∫(v*f)*dΩ

      op = AffineFEOperator(a,b,U,V)
      uh = solve(op)

      e = u - uh

      # Compute errors
      el2 = sqrt(sum( ∫( e*e )*dΩ ))
      eh1 = sqrt(sum( ∫( e*e + ∇(e)⋅∇(e) )*dΩ ))

      tol=1e-6
      println("$(el2) < $(tol)")
      println("$(eh1) < $(tol)")
      @assert el2 < tol
      @assert eh1 < tol
    end

    # This is for debuging
    coarse_model = setup_model(TVDc,perm)
    model = OctreeDistributedDiscreteModel(ranks, coarse_model, 0)

    #test_solve(model,order)


    ref_coarse_flags=map(ranks) do _
      [refine_flag,nothing_flag]
    end 
    dmodel,adaptivity_glue=adapt(model,ref_coarse_flags)
    non_conforming_glue=dmodel.non_conforming_glue

    test_solve(dmodel,order)
    for i=1:3
      ref_coarse_flags=map(ranks,partition(get_cell_gids(dmodel.dmodel))) do rank,indices
        flags=zeros(Cint,length(indices))
        flags.=nothing_flag
        
        #flags[1]=refine_flag
        flags[own_length(indices)]=refine_flag

        # # To create some unbalance
        # if (rank%2==0 && own_length(indices)>1)
        #     flags[div(own_length(indices),2)]=refine_flag
        # end     

        print("rank: $(rank) flags: $(flags)"); print("\n")
        flags
      end 

      dmodel,glue=adapt(dmodel,ref_coarse_flags);
      writevtk(Triangulation(dmodel),"trian")
      map(dmodel.dmodel.models) do model
        top=GridapDistributed.get_grid_topology(model)
        Gridap.Geometry.compute_cell_permutations(top,1)
      end
      # test_solve(dmodel,order)
    end
  end

  function run(distribute)
    ranks = distribute(LinearIndices((MPI.Comm_size(MPI.COMM_WORLD),)))
    for Dc=2:3, perm=1:4, order=1:4
       test(ranks,Val{Dc},perm,order)
    end
  end

end