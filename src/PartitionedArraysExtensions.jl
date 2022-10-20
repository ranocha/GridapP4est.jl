function PartitionedArrays.num_parts(comm::MPI.Comm)
  if comm != MPI.COMM_NULL
    nparts = MPI.Comm_size(comm)
  else
    nparts = -1
  end
  nparts
end

function PartitionedArrays.get_part_id(comm::MPI.Comm)
  if comm != MPI.COMM_NULL
    id = MPI.Comm_rank(comm)+1
  else
    id = -1
  end
  id
end

function i_am_in(comm::MPI.Comm)
  PartitionedArrays.get_part_id(comm) >=0
end

function i_am_in(parts)
  i_am_in(parts.comm)
end

function PartitionedArrays.get_part_ids(comm::MPI.Comm)
  rank = PartitionedArrays.get_part_id(comm)
  nparts = PartitionedArrays.num_parts(comm)
  PartitionedArrays.MPIData(rank,comm,(nparts,))
end


function PartitionedArrays.get_part_ids(b::MPIBackend,nparts::Union{Int,NTuple{N,Int} where N})
  root_comm = MPI.Comm_dup(MPI.COMM_WORLD)
  size = MPI.Comm_size(root_comm)
  rank = MPI.Comm_rank(root_comm) 
  need = prod(nparts)
  if size < need
    throw("Not enough MPI ranks, please run mpiexec with -n $need (at least)")
  elseif size > need
    if rank < need
      comm=MPI.Comm_split(root_comm, 0, 0)
      MPIData(PartitionedArrays.get_part_id(comm),comm,Tuple(nparts))
    else
      comm=MPI.Comm_split(root_comm, MPI.MPI_UNDEFINED, MPI.MPI_UNDEFINED)
      MPIData(PartitionedArrays.get_part_id(comm),comm,(-1,))
    end
  else
    comm = root_comm
    MPIData(PartitionedArrays.get_part_id(comm),comm,Tuple(nparts))
  end
end

function PartitionedArrays.prun(driver::Function,b::MPIBackend,nparts::Union{Int,NTuple{N,Int} where N},args...;kwargs...)
  if !MPI.Initialized()
    MPI.Init()
  end
  if MPI.Comm_size(MPI.COMM_WORLD) == 1
    part = get_part_ids(b,nparts)
    driver(part,args...;kwargs...)
  else
    try
       part = get_part_ids(b,nparts)
       if i_am_in(part) 
         driver(part,args...;kwargs...)
       end
    catch e
      @error "" exception=(e, catch_backtrace())
      if MPI.Initialized() && !MPI.Finalized()
        MPI.Abort(MPI.COMM_WORLD,1)
      end
    end
  end
  # We are NOT invoking MPI.Finalize() here because we rely on
  # MPI.jl, which registers MPI.Finalize() in atexit()
end

function generate_level_parts(parts,num_procs_x_level)
  root_comm = parts.comm
  rank = MPI.Comm_rank(root_comm)
  size = MPI.Comm_size(root_comm)
  Gridap.Helpers.@check all(num_procs_x_level .<= size)
  Gridap.Helpers.@check all(num_procs_x_level .>= 1)

  level_parts=Vector{typeof(parts)}(undef,length(num_procs_x_level))
  for l=1:length(num_procs_x_level)
    lsize=num_procs_x_level[l]
    if l>1 && lsize==num_procs_x_level[l-1]
      level_parts[l]=level_parts[l-1]
    else
      if rank < lsize
        comm=MPI.Comm_split(root_comm, 0, 0)
      else
        comm=MPI.Comm_split(root_comm, MPI.MPI_UNDEFINED, MPI.MPI_UNDEFINED)
      end
      level_parts[l]=get_part_ids(comm)
    end
  end
  return level_parts
end