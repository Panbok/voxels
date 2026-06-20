package async

import world_async "async:world"

import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

//////////////////////////////////////
// Generation Constants
/////////////////////////////////////

GENERATION_WORKER_COUNT_DEFAULT :: 4
GENERATION_WORKER_COUNT_MIN :: 1

GENERATION_QUEUE_CAPACITY :: 128
GENERATION_RESULT_QUEUE_CAPACITY :: 128

//////////////////////////////////////
// Meshing Constants
/////////////////////////////////////

MESH_WORKER_COUNT_DEFAULT :: 4
MESH_WORKER_COUNT_MIN :: 1
MESH_WORKER_ARENA_BYTES :: 8 * mem.Megabyte
MESH_WORKER_SCRATCH_ARENA_BYTES :: 3 * mem.Megabyte

MESH_QUEUE_CAPACITY :: 128

//////////////////////////////////////
// Types
/////////////////////////////////////

state := struct {
	// Memory
	allocator:                 mem.Allocator,
	generation_execute:        GenerationExecuteProc,
	mesh_execute:              MeshExecuteProc,

	// Sync
	generation_mutex:          sync.Mutex,
	mesh_mutex:                sync.Mutex,

	// State
	shutdown_requested:        bool,
	started:                   bool,

	// Generation
	generation_work_available: sync.Sema,
	generation_worker_count:   u32,
	generation_threads:        []^thread.Thread,
	generation_contexts:       []GenerationWorkerContext,
	generation_jobs:           [GENERATION_QUEUE_CAPACITY]world_async.ChunkGenerationJob,
	generation_job_head:       u32,
	generation_job_tail:       u32,
	generation_job_count:      u32,
	generation_results:        [GENERATION_RESULT_QUEUE_CAPACITY]world_async.ChunkGenerationJobResult,
	generation_result_head:    u32,
	generation_result_tail:    u32,
	generation_result_count:   u32,

	// Meshing
	mesh_work_available:       sync.Sema,
	mesh_worker_count:         u32,
	mesh_result_released:      []sync.Sema,
	mesh_threads:              []^thread.Thread,
	mesh_contexts:             []MeshWorkerContext,
	mesh_worker_arena_pool:    MeshWorkerArenaPool,
	mesh_worker_scratch_pool:  MeshWorkerArenaPool,
	mesh_result_pending:       []bool,
	mesh_jobs:                 [MESH_QUEUE_CAPACITY]world_async.ChunkMeshJob,
	mesh_job_head:             u32,
	mesh_job_tail:             u32,
	mesh_job_count:            u32,
	mesh_results:              []world_async.ChunkMeshJobResult,
	mesh_result_head:          u32,
	mesh_result_tail:          u32,
	mesh_result_count:         u32,
}{}

GenerationExecuteProc :: #type proc(
	job: world_async.ChunkGenerationJob,
) -> world_async.ChunkGenerationJobResult
MeshExecuteProc :: #type proc(
	job: world_async.ChunkMeshJob,
	output_allocator: mem.Allocator,
	scratch_allocator: mem.Allocator,
) -> world_async.ChunkMeshOutput

InitConfig :: struct {
	allocator:               mem.Allocator,
	generation_worker_count: u32,
	mesh_worker_count:       u32,
	generation_execute:      GenerationExecuteProc,
	mesh_execute:            MeshExecuteProc,
}

//////////////////////////////////////
// Worker Types
/////////////////////////////////////

MeshWorkerArenaPoolElement :: struct {
	arena:     mem.Arena,
	allocator: mem.Allocator,
	buffer:    []u8,
}

MeshWorkerArenaPool :: struct {
	elements: []MeshWorkerArenaPoolElement,
}

GenerationWorkerContext :: struct {
	worker_index: u32,
}

MeshWorkerContext :: struct {
	worker_index: u32,
}

//////////////////////////////////////
// Lifecycle State Methods
/////////////////////////////////////

lifecycle_started :: proc() -> bool {
	return sync.atomic_load_explicit(&state.started, .Acquire)
}

lifecycle_shutdown_requested :: proc() -> bool {
	return sync.atomic_load_explicit(&state.shutdown_requested, .Acquire)
}

lifecycle_started_set :: proc(value: bool) {
	sync.atomic_store_explicit(&state.started, value, .Release)
}

lifecycle_shutdown_requested_set :: proc(value: bool) {
	sync.atomic_store_explicit(&state.shutdown_requested, value, .Release)
}

//////////////////////////////////////
// Queue Methods
/////////////////////////////////////

queue_advance :: proc(index, capacity: u32) -> u32 {
	return (index + 1) % capacity
}

mesh_result_queue_capacity :: proc() -> u32 {
	return u32(len(state.mesh_results))
}

//////////////////////////////////////
// Generation Queue Methods
/////////////////////////////////////

generation_job_push_locked :: proc(job: world_async.ChunkGenerationJob) -> bool {
	if state.generation_job_count >= GENERATION_QUEUE_CAPACITY {
		return false
	}

	state.generation_jobs[state.generation_job_tail] = job
	state.generation_job_tail = queue_advance(state.generation_job_tail, GENERATION_QUEUE_CAPACITY)
	state.generation_job_count += 1
	return true
}

generation_job_pop_locked :: proc(job: ^world_async.ChunkGenerationJob) -> bool {
	if state.generation_job_count == 0 {
		return false
	}

	job^ = state.generation_jobs[state.generation_job_head]
	state.generation_job_head = queue_advance(state.generation_job_head, GENERATION_QUEUE_CAPACITY)
	state.generation_job_count -= 1
	return true
}

generation_result_push_locked :: proc(result: world_async.ChunkGenerationJobResult) {
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

generation_result_pop_locked :: proc(result: ^world_async.ChunkGenerationJobResult) -> bool {
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

//////////////////////////////////////
// Meshing Queue Methods
/////////////////////////////////////

mesh_job_push_locked :: proc(job: world_async.ChunkMeshJob) -> bool {
	if state.mesh_job_count >= MESH_QUEUE_CAPACITY {
		return false
	}

	state.mesh_jobs[state.mesh_job_tail] = job
	state.mesh_job_tail = queue_advance(state.mesh_job_tail, MESH_QUEUE_CAPACITY)
	state.mesh_job_count += 1
	return true
}

mesh_job_pop_locked :: proc(job: ^world_async.ChunkMeshJob) -> bool {
	if state.mesh_job_count == 0 {
		return false
	}

	job^ = state.mesh_jobs[state.mesh_job_head]
	state.mesh_job_head = queue_advance(state.mesh_job_head, MESH_QUEUE_CAPACITY)
	state.mesh_job_count -= 1
	return true
}

mesh_result_push_locked :: proc(result: world_async.ChunkMeshJobResult) {
	capacity := mesh_result_queue_capacity()
	log.assertf(state.mesh_result_count < capacity, "mesh result queue capacity exceeded")

	state.mesh_results[state.mesh_result_tail] = result
	state.mesh_result_tail = queue_advance(state.mesh_result_tail, capacity)
	state.mesh_result_count += 1
}

mesh_result_pop_locked :: proc(result: ^world_async.ChunkMeshJobResult) -> bool {
	if state.mesh_result_count == 0 {
		return false
	}

	result^ = state.mesh_results[state.mesh_result_head]
	state.mesh_result_head = queue_advance(state.mesh_result_head, mesh_result_queue_capacity())
	state.mesh_result_count -= 1
	return true
}

//////////////////////////////////////
// Meshing Worker Memory Methods
/////////////////////////////////////

mesh_worker_arena_pool_init :: proc(
	pool: ^MeshWorkerArenaPool,
	arena_count: u32,
	buffer_size: u32,
	allocator: mem.Allocator,
) {
	log.assertf(pool != nil, "mesh arena pool must not be nil")
	log.assertf(arena_count > 0, "mesh arena count must be positive")

	pool^ = {}
	pool.elements = make([]MeshWorkerArenaPoolElement, int(arena_count), allocator)
	log.assertf(
		len(pool.elements) == int(arena_count),
		"mesh arena pool element allocation failed: expected=%d got=%d",
		arena_count,
		len(pool.elements),
	)

	for idx in 0 ..< arena_count {
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

mesh_worker_arena_pool_destroy :: proc(pool: ^MeshWorkerArenaPool) {
	if pool == nil {
		return
	}

	pool^ = {}
}

mesh_worker_arena_pool_reset_element :: proc(pool: ^MeshWorkerArenaPool, index: u32) {
	log.assertf(index < u32(len(pool.elements)), "mesh arena index out of bounds: %d", index)
	mem.arena_free_all(&pool.elements[index].arena)
}

//////////////////////////////////////
// Generation Worker Methods
/////////////////////////////////////

generation_worker_proc :: proc(data: rawptr) {
	ctx := (^GenerationWorkerContext)(data)
	_ = ctx

	for {
		sync.wait(&state.generation_work_available)

		if lifecycle_shutdown_requested() {
			return
		}

		job: world_async.ChunkGenerationJob
		sync.lock(&state.generation_mutex)
		got_job := generation_job_pop_locked(&job)
		execute := state.generation_execute
		sync.unlock(&state.generation_mutex)

		if !got_job {
			continue
		}

		generation_start := time.tick_now()
		result := execute(job)
		result.generation_duration_us = u64(
			time.duration_microseconds(time.tick_since(generation_start)),
		)

		sync.lock(&state.generation_mutex)
		generation_result_push_locked(result)
		sync.unlock(&state.generation_mutex)
	}
}

//////////////////////////////////////
// Meshing Worker Methods
/////////////////////////////////////

mesh_worker_proc :: proc(data: rawptr) {
	ctx := (^MeshWorkerContext)(data)
	worker_index := ctx.worker_index

	for {
		if lifecycle_shutdown_requested() {
			return
		}

		sync.lock(&state.mesh_mutex)
		if state.mesh_result_pending[worker_index] {
			sync.unlock(&state.mesh_mutex)
			sync.wait(&state.mesh_result_released[worker_index])
			continue
		}

		job: world_async.ChunkMeshJob
		got_job := mesh_job_pop_locked(&job)
		execute := state.mesh_execute
		sync.unlock(&state.mesh_mutex)

		if !got_job {
			sync.wait(&state.mesh_work_available)
			continue
		}

		mesh_worker_arena_pool_reset_element(&state.mesh_worker_arena_pool, worker_index)
		mesh_worker_arena_pool_reset_element(&state.mesh_worker_scratch_pool, worker_index)
		output := execute(
			job,
			state.mesh_worker_arena_pool.elements[worker_index].allocator,
			state.mesh_worker_scratch_pool.elements[worker_index].allocator,
		)

		result := world_async.ChunkMeshJobResult {
			coord          = job.snapshot.coord,
			block_version  = job.snapshot.block_version,
			scope_kind     = job.scope_kind,
			subchunk_index = job.subchunk_index,
			worker_index   = worker_index,
			output         = output,
		}

		sync.lock(&state.mesh_mutex)
		state.mesh_result_pending[worker_index] = true
		mesh_result_push_locked(result)
		sync.unlock(&state.mesh_mutex)
	}
}

//////////////////////////////////////
// Lifecycle Methods
/////////////////////////////////////

init :: proc(config: InitConfig) {
	if lifecycle_started() {
		return
	}

	log.assert(config.generation_execute != nil, "generation execute callback is required")
	log.assert(config.mesh_execute != nil, "mesh execute callback is required")

	generation_worker_count := config.generation_worker_count
	if generation_worker_count == 0 {
		generation_worker_count = GENERATION_WORKER_COUNT_DEFAULT
	}
	mesh_worker_count := config.mesh_worker_count
	if mesh_worker_count == 0 {
		mesh_worker_count = MESH_WORKER_COUNT_DEFAULT
	}
	log.assertf(
		generation_worker_count >= GENERATION_WORKER_COUNT_MIN,
		"generation worker count must be positive",
	)
	log.assertf(mesh_worker_count >= MESH_WORKER_COUNT_MIN, "mesh worker count must be positive")

	state.allocator = config.allocator
	state.generation_execute = config.generation_execute
	state.mesh_execute = config.mesh_execute
	state.generation_worker_count = generation_worker_count
	state.mesh_worker_count = mesh_worker_count
	state.generation_threads = make(
		[]^thread.Thread,
		int(generation_worker_count),
		config.allocator,
	)
	state.generation_contexts = make(
		[]GenerationWorkerContext,
		int(generation_worker_count),
		config.allocator,
	)
	state.mesh_result_released = make([]sync.Sema, int(mesh_worker_count), config.allocator)
	state.mesh_threads = make([]^thread.Thread, int(mesh_worker_count), config.allocator)
	state.mesh_contexts = make([]MeshWorkerContext, int(mesh_worker_count), config.allocator)
	state.mesh_result_pending = make([]bool, int(mesh_worker_count), config.allocator)
	state.mesh_results = make(
		[]world_async.ChunkMeshJobResult,
		int(mesh_worker_count),
		config.allocator,
	)
	lifecycle_shutdown_requested_set(false)
	mesh_worker_arena_pool_init(
		&state.mesh_worker_arena_pool,
		mesh_worker_count,
		MESH_WORKER_ARENA_BYTES,
		config.allocator,
	)
	mesh_worker_arena_pool_init(
		&state.mesh_worker_scratch_pool,
		mesh_worker_count,
		MESH_WORKER_SCRATCH_ARENA_BYTES,
		config.allocator,
	)

	for worker_index in 0 ..< generation_worker_count {
		state.generation_contexts[worker_index] = {
			worker_index = u32(worker_index),
		}
		state.generation_threads[worker_index] = thread.create_and_start_with_data(
			rawptr(&state.generation_contexts[worker_index]),
			generation_worker_proc,
		)
		log.assertf(
			state.generation_threads[worker_index] != nil,
			"failed to create async generation worker",
		)
	}

	for worker_index in 0 ..< mesh_worker_count {
		state.mesh_contexts[worker_index] = {
			worker_index = u32(worker_index),
		}
		state.mesh_threads[worker_index] = thread.create_and_start_with_data(
			rawptr(&state.mesh_contexts[worker_index]),
			mesh_worker_proc,
		)
		log.assertf(state.mesh_threads[worker_index] != nil, "failed to create async mesh worker")
	}

	lifecycle_started_set(true)
}

shutdown :: proc() {
	if !lifecycle_started() {
		return
	}

	lifecycle_shutdown_requested_set(true)

	sync.post(&state.generation_work_available, int(state.generation_worker_count))
	sync.post(&state.mesh_work_available, int(state.mesh_worker_count))
	for worker_index in 0 ..< state.mesh_worker_count {
		sync.post(&state.mesh_result_released[worker_index])
	}

	for worker_index in 0 ..< state.generation_worker_count {
		thread.join(state.generation_threads[worker_index])
		thread.destroy(state.generation_threads[worker_index])
		state.generation_threads[worker_index] = nil
	}

	for worker_index in 0 ..< state.mesh_worker_count {
		thread.join(state.mesh_threads[worker_index])
		thread.destroy(state.mesh_threads[worker_index])
		state.mesh_threads[worker_index] = nil
	}

	mesh_worker_arena_pool_destroy(&state.mesh_worker_arena_pool)
	mesh_worker_arena_pool_destroy(&state.mesh_worker_scratch_pool)

	lifecycle_started_set(false)
	lifecycle_shutdown_requested_set(false)
	state = {}
}

//////////////////////////////////////
// Generation Methods
/////////////////////////////////////

generation_request :: proc(job: world_async.ChunkGenerationJob) -> bool {
	if !lifecycle_started() || lifecycle_shutdown_requested() {
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

generation_results_poll :: proc(results: []world_async.ChunkGenerationJobResult) -> u32 {
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

mesh_request :: proc(job: world_async.ChunkMeshJob) -> bool {
	if !lifecycle_started() || lifecycle_shutdown_requested() {
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

mesh_results_poll :: proc(results: []world_async.ChunkMeshJobResult) -> u32 {
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

mesh_result_release :: proc(result: world_async.ChunkMeshJobResult) {
	log.assertf(
		result.worker_index < state.mesh_worker_count,
		"mesh result worker index out of bounds",
	)

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
