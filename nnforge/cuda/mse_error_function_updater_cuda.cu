/*
 *  Copyright 2011-2014 Maxim Milakov
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#include "mse_error_function_updater_cuda.h"

#include "../mse_error_function.h"

namespace nnforge
{
	namespace cuda
	{
		__forceinline__ __device__ double atomicAdd(double* address, double val)
		{
				unsigned long long int* address_as_ull = (unsigned long long int*)address;
				unsigned long long int old = *address_as_ull, assumed;
				do {
					assumed = old;
					old = atomicCAS(address_as_ull, assumed, __double_as_longlong(val + __longlong_as_double(assumed)));
				} while (assumed != old);
				return __longlong_as_double(old);
		}

		extern __shared__ float arr_sh[];
		__global__ void mse_update_error_and_gradient_kernel(
			float * __restrict gradients,
			double * __restrict total_error,
			const float * __restrict actual_output_neurons,
			const float * __restrict predicted_output_neurons,
			int offset_entry_id,
			int neuron_count,
			int updater_entry_count)
		{
			int neuron_id = blockIdx.y * blockDim.x + threadIdx.x;
			int updater_entry_id = blockIdx.x;

			int offset = updater_entry_id * neuron_count + neuron_id;
			float err = 0.0F;
			if (neuron_id < neuron_count)
			{
				float actual_val = actual_output_neurons[(offset_entry_id + updater_entry_id) * neuron_count + neuron_id];
				float predicted_val = predicted_output_neurons[offset];
				err = actual_val - predicted_val;
				gradients[offset] = err;
			}

			err *= err;
			int thread_id = threadIdx.x;
			int lane_id = thread_id & 31;
			#pragma unroll
			for(int tx = 16; tx > 0; tx >>= 1)
			{
				err += __shfl_down(err, tx);
			}

			if (blockDim.x > 32)
			{
				if (lane_id == 0)
					arr_sh[thread_id >> 5] = err;
				__syncthreads();
			}

			if (thread_id == 0)
			{
				for(int i = 1; i < (blockDim.x >> 5); ++i)
					err += arr_sh[i];
				err *= 0.5F;
				double err_d = (double)err;

				atomicAdd(total_error, err_d);
			}
		}

		mse_error_function_updater_cuda::mse_error_function_updater_cuda()
		{
		}

		mse_error_function_updater_cuda::~mse_error_function_updater_cuda()
		{
		}

		const boost::uuids::uuid& mse_error_function_updater_cuda::get_uuid() const
		{
			return mse_error_function::function_guid;
		}

		void mse_error_function_updater_cuda::enqueue_update_error_and_gradient(
			cudaStream_t stream_id,
			cuda_linear_buffer_device_smart_ptr gradient_buffer,
			cuda_linear_buffer_device_smart_ptr error_buffer,
			const_cuda_linear_buffer_device_smart_ptr actual_output_buffer,
			const_cuda_linear_buffer_device_smart_ptr predicted_output_buffer,
			unsigned int offset_entry_id,
			unsigned int neuron_count,
			unsigned int updater_entry_count) const
		{
			int threadblock_size = get_threadblock_size(neuron_count);
			int block_count = (neuron_count + threadblock_size - 1) / threadblock_size;
			dim3 grid_size(updater_entry_count, block_count, 1);
			dim3 block_size(threadblock_size, 1, 1);

			int smem_size = threadblock_size * sizeof(float);
			mse_update_error_and_gradient_kernel<<<grid_size, block_size, smem_size, stream_id>>>(
				*gradient_buffer,
				*error_buffer,
				*actual_output_buffer,
				*predicted_output_buffer,
				offset_entry_id,
				neuron_count,
				updater_entry_count);
		}

		int mse_error_function_updater_cuda::get_threadblock_size(int output_neuron_count)
		{
			int threadblock_size;

			if (output_neuron_count < 256)
			{
				threadblock_size = (output_neuron_count + 32 - 1) / 32 * 32;
			}
			else
			{
				int threadblock_count = (output_neuron_count + 256 - 1) / 256;
				threadblock_size = (output_neuron_count + threadblock_count - 1) / threadblock_count;
				threadblock_size = (threadblock_size + 32 - 1) / 32 * 32;
			}

			return threadblock_size;
		}
	}
}
