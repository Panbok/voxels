package async

import world "../world"

import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"

//////////////////////////////////////
// Generation Constants
/////////////////////////////////////

GENERATION_WORKER_COUNT :: 4

GENERATION_QUEUE_CAPACITY :: 128
GENERATION_RESULT_QUEUE_CAPACITY :: 128

//////////////////////////////////////
// Meshing Constants
/////////////////////////////////////

MESH_WORKER_COUNT :: 4
MESH_WORKER_ARENA_BYTES :: 8 * mem.Megabyte

MESH_QUEUE_CAPACITY :: 128
MESH_RESULT_QUEUE_CAPACITY :: MESH_WORKER_COUNT

//////////////////////////////////////
// Types
/////////////////////////////////////

state := struct {
	// Memory
	allocator:          mem.Allocator,
	generation_execute: GenerationExecuteProc,
	mesh_execute:       MeshExecuteProc,

	// Sync
	generation_mutex:   sync.Mutex,
	mesh_mutex:         sync.Mutex,

	// State
	shutdown_requested: bool,
	started:            bool,

	// Generation
	generation_work_available: sync.Sema,
	generation_threads:        [GENERATION_WORKER_COUNT]^thread.Thread,
	generation_contexts:       [GENERATION_WORKER_COUNT]GenerationWorkerContext,
	generation_jobs:           [GENERATION_QUEUE_CAPACITY]ChunkGenerationJob,
	generation_job_head:       u32,
	generation_job_tail:       u32,
	generation_job_count:      u32,
	generation_results:        [GENERATION_RESULT_QUEUE_CAPACITY]ChunkGenerationJobResult,
	generation_result_head:    u32,
	generation_result_tail:    u32,
	generation_result_count:   u32,

	// Meshing
	mesh_work_available:   sync.Sema,
	mesh_result_released:  [MESH_WORKER_COUNT]sync.Sema,
	mesh_threads:          [MESH_WORKER_COUNT]^thread.Thread,
	mesh_contexts:         [MESH_WORKER_COUNT]MeshWorkerContext,
	mesh_worker_arena_pool: ArenaPool,
	mesh_result_pending:   [MESH_WORKER_COUNT]bool,
	mesh_jobs:             [MESH_QUEUE_CAPACITY]ChunkMeshJob,
	mesh_job_head:         u32,
	mesh_job_tail:         u32,
	mesh_job_count:        u32,
	mesh_results:          [MESH_RESULT_QUEUE_CAPACITY]ChunkMeshJobResult,
	mesh_result_head:      u32,
	mesh_result_tail:      u32,
	mesh_result_count:     u32,
}{}

GenerationExecuteProc :: #type proc(job: ChunkGenerationJob) -> ChunkGenerationJobResult
MeshExecuteProc :: #type proc(job: ChunkMeshJob, output_allocator: mem.Allocator) -> world.ChunkMeshOutput

InitConfig :: struct {
	allocator:          mem.Allocator,
	generation_execute: GenerationExecuteProc,
	mesh_execute:       MeshExecuteProc,
}

//////////////////////////////////////
// Generation Types
/////////////////////////////////////

ChunkGenerationJob :: struct {
	coord:         world.ChunkCoord,
	seed:          u32,
	block_storage: world.ChunkBlockStorage,
}

ChunkGenerationJobResult :: struct {
	coord:         world.ChunkCoord,
	block_storage: world.ChunkBlockStorage,
}

//////////////////////////////////////
// Meshing Types
/////////////////////////////////////

ChunkMeshJob :: struct {
	snapshot:         world.ChunkSnapshot,
	neighbors:        world.ChunkMeshNeighborSnapshots,
	boundary_policy:  world.ChunkMeshBoundaryPolicy,
}

ChunkMeshJobResult :: struct {
	coord:         world.ChunkCoord,
	block_version: u32,
	worker_index:  u32,
	output:        world.ChunkMeshOutput,
}

//////////////////////////////////////
// Worker Types
/////////////////////////////////////

ArenaPoolElement :: struct {
	arena:     mem.Arena,
	allocator: mem.Allocator,
	buffer:    []u8,
}

ArenaPool :: struct {
	elements: [MESH_WORKER_COUNT]ArenaPoolElement,
}

GenerationWorkerContext :: struct {
	worker_index: u32,
}

MeshWorkerContext :: struct {
	worker_index: u32,
}

//////////////////////////////////////
// Queue Methods
/////////////////////////////////////

async_started :: proc() -> bool {
	return sync.atomic_load_explicit(&state.started, .Acquire)
}

async_shutdown_requested :: proc() -> bool {
	return sync.atomic_load_explicit(&state.shutdown_requested, .Acquire)
}

async_set_started :: proc(value: bool) {
	sync.atomic_store_explicit(&state.started, value, .Release)
}

async_set_shutdown_requested :: proc(value: bool) {
	sync.atomic_store_explicit(&state.shutdown_requested, value, .Release)
}

queue_advance :: proc(index, capacity: u32) -> u32 {
	return (index + 1) % capacity
}

generation_job_push_locked :: proc(job: ChunkGenerationJob) -> bool {
	if state.generation_job_count >= GENERATION_QUEUE_CAPACITY {
		return false
	}

	state.generation_jobs[state.generation_job_tail] = job
	state.generation_job_tail = queue_advance(state.generation_job_tail, GENERATION_QUEUE_CAPACITY)
	state.generation_job_count += 1
	return true
}

generation_job_pop_locked :: proc(job: ^ChunkGenerationJob) -> bool {
	if state.generation_job_count == 0 {
		return false
	}

	job^ = state.generation_jobs[state.generation_job_head]
	state.generation_job_head = queue_advance(state.generation_job_head, GENERATION_QUEUE_CAPACITY)
	state.generation_job_count -= 1
	return true
}

generation_result_push_locked :: proc(result: ChunkGenerationJobResult) {
	log.assertf(
		state.generation_result_count < GENERATION_RESULT_QUEUE_CAPACITY,
		"generation result queue capacity exceeded",
	)

	state.generation_results[state.generation_result_tail] = result
	state.generation_result_tail = queue_advance(
		state.generation_result_tail,
		GENERATION_RESULT_QUEUE_CAPACITY,
	)
	state.generation_result_count += 1
}

generation_result_pop_locked :: proc(result: ^ChunkGenerationJobResult) -> bool {
	if state.generation_result_count == 0 {
		return false
	}

	result^ = state.generation_results[state.generation_result_head]
	state.generation_result_head = queue_advance(
		state.generation_result_head,
		GENERATION_RESULT_QUEUE_CAPACITY,
	)
	state.generation_result_count -= 1
	return true
}

mesh_job_push_locked :: proc(job: ChunkMeshJob) -> bool {
	if state.mesh_job_count >= MESH_QUEUE_CAPACITY {
		return false
	}

	state.mesh_jobs[state.mesh_job_tail] = job
	state.mesh_job_tail = queue_advance(state.mesh_job_tail, MESH_QUEUE_CAPACITY)
	state.mesh_job_count += 1
	return true
}

mesh_job_pop_locked :: proc(job: ^ChunkMeshJob) -> bool {
	if state.mesh_job_count == 0 {
		return false
	}

	job^ = state.mesh_jobs[state.mesh_job_head]
	state.mesh_job_head = queue_advance(state.mesh_job_head, MESH_QUEUE_CAPACITY)
	state.mesh_job_count -= 1
	return true
}

mesh_result_push_locked :: proc(result: ChunkMeshJobResult) {
	log.assertf(
		state.mesh_result_count < MESH_RESULT_QUEUE_CAPACITY,
		"mesh result queue capacity exceeded",
	)

	state.mesh_results[state.mesh_result_tail] = result
	state.mesh_result_tail = queue_advance(state.mesh_result_tail, MESH_RESULT_QUEUE_CAPACITY)
	state.mesh_result_count += 1
}

mesh_result_pop_locked :: proc(result: ^ChunkMeshJobResult) -> bool {
	if state.mesh_result_count == 0 {
		return false
	}

	result^ = state.mesh_results[state.mesh_result_head]
	state.mesh_result_head = queue_advance(state.mesh_result_head, MESH_RESULT_QUEUE_CAPACITY)
	state.mesh_result_count -= 1
	return true
}

//////////////////////////////////////
// Worker Memory Methods
/////////////////////////////////////

arena_pool_init :: proc(pool: ^ArenaPool, arena_count: u32, buffer_size: u32, allocator: mem.Allocator) {
	log.assertf(pool != nil, "mesh arena pool must not be nil")
	log.assertf(arena_count == MESH_WORKER_COUNT, "mesh arena count must match mesh worker count")

	pool^ = {}
	for idx in 0 ..< MESH_WORKER_COUNT {
		pool.elements[idx] = {
			arena     = mem.Arena{},
			allocator = mem.Allocator{},
			buffer    = make([]u8, buffer_size, allocator),
		}
		log.assertf(
			len(pool.elements[idx].buffer) == int(buffer_size),
			"mesh worker arena allocation failed: worker=%d bytes=%d got=%d",
			idx,
			buffer_size,
			len(pool.elements[idx].buffer),
		)

		mem.arena_init(&pool.elements[idx].arena, pool.elements[idx].buffer)
		pool.elements[idx].allocator = mem.arena_allocator(&pool.elements[idx].arena)
	}
}

arena_pool_reset_element :: proc(pool: ^ArenaPool, index: u32) {
	log.assertf(index < MESH_WORKER_COUNT, "mesh arena index out of bounds: %d", index)
	mem.arena_free_all(&pool.elements[index].arena)
}

//////////////////////////////////////
// Worker Methods
/////////////////////////////////////

generation_worker_proc :: proc(data: rawptr) {
	ctx := (^GenerationWorkerContext)(data)
	_ = ctx

	for {
		sync.wait(&state.generation_work_available)

		if async_shutdown_requested() {
			return
		}

		job: ChunkGenerationJob
		sync.lock(&state.generation_mutex)
		got_job := generation_job_pop_locked(&job)
		execute := state.generation_execute
		sync.unlock(&state.generation_mutex)

		if !got_job {
			continue
		}

		result := execute(job)

		sync.lock(&state.generation_mutex)
		generation_result_push_locked(result)
		sync.unlock(&state.generation_mutex)
	}
}

mesh_worker_proc :: proc(data: rawptr) {
	ctx := (^MeshWorkerContext)(data)
	worker_index := ctx.worker_index

	for {
		if async_shutdown_requested() {
			return
		}

		sync.lock(&state.mesh_mutex)
		if state.mesh_result_pending[worker_index] {
			sync.unlock(&state.mesh_mutex)
			sync.wait(&state.mesh_result_released[worker_index])
			continue
		}

		job: ChunkMeshJob
		got_job := mesh_job_pop_locked(&job)
		execute := state.mesh_execute
		sync.unlock(&state.mesh_mutex)

		if !got_job {
			sync.wait(&state.mesh_work_available)
			continue
		}

		arena_pool_reset_element(&state.mesh_worker_arena_pool, worker_index)
		output := execute(job, state.mesh_worker_arena_pool.elements[worker_index].allocator)

		result := ChunkMeshJobResult {
			coord         = job.snapshot.coord,
			block_version = job.snapshot.block_version,
			worker_index  = worker_index,
			output        = output,
		}

		sync.lock(&state.mesh_mutex)
		state.mesh_result_pending[worker_index] = true
		mesh_result_push_locked(result)
		sync.unlock(&state.mesh_mutex)
	}
}

//////////////////////////////////////
// Methods
/////////////////////////////////////

init :: proc(config: InitConfig) {
	if async_started() {
		return
	}

	log.assert(config.generation_execute != nil, "generation execute callback is required")
	log.assert(config.mesh_execute != nil, "mesh execute callback is required")

	state.allocator = config.allocator
	state.generation_execute = config.generation_execute
	state.mesh_execute = config.mesh_execute
	async_set_shutdown_requested(false)
	arena_pool_init(
		&state.mesh_worker_arena_pool,
		MESH_WORKER_COUNT,
		MESH_WORKER_ARENA_BYTES,
		config.allocator,
	)

	for worker_index in 0 ..< GENERATION_WORKER_COUNT {
		state.generation_contexts[worker_index] = {worker_index = u32(worker_index)}
		state.generation_threads[worker_index] = thread.create_and_start_with_data(
			rawptr(&state.generation_contexts[worker_index]),
			generation_worker_proc,
		)
		log.assertf(
			state.generation_threads[worker_index] != nil,
			"failed to create async generation worker",
		)
	}

	for worker_index in 0 ..< MESH_WORKER_COUNT {
		state.mesh_contexts[worker_index] = {worker_index = u32(worker_index)}
		state.mesh_threads[worker_index] = thread.create_and_start_with_data(
			rawptr(&state.mesh_contexts[worker_index]),
			mesh_worker_proc,
		)
		log.assertf(state.mesh_threads[worker_index] != nil, "failed to create async mesh worker")
	}

	async_set_started(true)
}

shutdown :: proc() {
	if !async_started() {
		return
	}

	async_set_shutdown_requested(true)

	sync.post(&state.generation_work_available, GENERATION_WORKER_COUNT)
	sync.post(&state.mesh_work_available, MESH_WORKER_COUNT)
	for worker_index in 0 ..< MESH_WORKER_COUNT {
		sync.post(&state.mesh_result_released[worker_index])
	}

	for worker_index in 0 ..< GENERATION_WORKER_COUNT {
		thread.join(state.generation_threads[worker_index])
		thread.destroy(state.generation_threads[worker_index])
		state.generation_threads[worker_index] = nil
	}

	for worker_index in 0 ..< MESH_WORKER_COUNT {
		thread.join(state.mesh_threads[worker_index])
		thread.destroy(state.mesh_threads[worker_index])
		state.mesh_threads[worker_index] = nil
	}

	async_set_started(false)
	async_set_shutdown_requested(false)
}

//////////////////////////////////////
// Generation Methods
/////////////////////////////////////

request_generation :: proc(job: ChunkGenerationJob) -> bool {
	if !async_started() || async_shutdown_requested() {
		return false
	}

	sync.lock(&state.generation_mutex)
	queued := generation_job_push_locked(job)
	sync.unlock(&state.generation_mutex)

	if queued {
		sync.post(&state.generation_work_available)
	}
	return queued
}

poll_generation_results :: proc(results: []ChunkGenerationJobResult) -> u32 {
	result_count: u32

	sync.lock(&state.generation_mutex)
	for int(result_count) < len(results) {
		if !generation_result_pop_locked(&results[result_count]) {
			break
		}
		result_count += 1
	}
	sync.unlock(&state.generation_mutex)

	return result_count
}

//////////////////////////////////////
// Meshing Methods
/////////////////////////////////////

request_mesh :: proc(job: ChunkMeshJob) -> bool {
	if !async_started() || async_shutdown_requested() {
		return false
	}

	sync.lock(&state.mesh_mutex)
	queued := mesh_job_push_locked(job)
	sync.unlock(&state.mesh_mutex)

	if queued {
		sync.post(&state.mesh_work_available)
	}
	return queued
}

poll_mesh_results :: proc(results: []ChunkMeshJobResult) -> u32 {
	result_count: u32

	sync.lock(&state.mesh_mutex)
	for int(result_count) < len(results) {
		if !mesh_result_pop_locked(&results[result_count]) {
			break
		}
		result_count += 1
	}
	sync.unlock(&state.mesh_mutex)

	return result_count
}

release_mesh_result :: proc(result: ChunkMeshJobResult) {
	log.assertf(result.worker_index < MESH_WORKER_COUNT, "mesh result worker index out of bounds")

	sync.lock(&state.mesh_mutex)
	log.assertf(
		state.mesh_result_pending[result.worker_index],
		"mesh result was already released: worker_index=%d",
		result.worker_index,
	)
	state.mesh_result_pending[result.worker_index] = false
	sync.unlock(&state.mesh_mutex)

	sync.post(&state.mesh_result_released[result.worker_index])
}
