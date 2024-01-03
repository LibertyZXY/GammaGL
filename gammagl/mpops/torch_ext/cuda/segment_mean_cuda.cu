#include <ATen/cuda/CUDAContext.h>
#include <assert.h>
#include <cuda.h>
#include <torch/script.h>
#include <torch/torch.h>

#include <cstdint>
#include <iostream>
#include <vector>

#include "ATen/Functions.h"
#include "ATen/core/TensorBody.h"
#include "segment_mean_cuda.h"

using torch::autograd::AutogradContext;
using torch::autograd::Variable;
using torch::autograd::variable_list;

#define THREADS 1024
#define BLOCKS(N) (N + THREADS - 1) / THREADS

// inline __device__ void atomic_max_float(float *addr, float value) {
//   int *addr_as_i = (int *)addr;
//   int old = *addr_as_i;
//   int assumed;
//   do{
//     assumed = old;
//     old = atomicCAS(addr_as_i, assumed,
//                     __float_as_int(max(value, __int_as_float(assumed))));
//   } while (assumed != old);
// }

template <typename scalar_t>
__global__ void segment_mean_cuda_forward_kernel(
    const scalar_t *x_data, const int64_t *index_data, scalar_t *out_data,
    scalar_t *count_data, int64_t E, int64_t K, int64_t N, int64_t numel) {
  int64_t thread_idx = blockIdx.x * blockDim.x + threadIdx.x;
  int64_t e = (thread_idx / K) % E;
  int64_t k = thread_idx % K;
  if (thread_idx < numel) {
    // TODO: support more data type
    int64_t idx = index_data[e];
    atomicAdd(out_data + idx * K + k, x_data[thread_idx]);
    atomicAdd(count_data + idx * K + k, 1.);
  }
}

// TODO: fuse segment & arg_segment to one kernel function.
template <typename scalar_t>
__global__ void arg_segment_mean_cuda_forward_kernel(
    const scalar_t *x_data, const int64_t *index_data, scalar_t *out_data,
    int64_t *arg_out_data, scalar_t *count_data, int64_t E, int64_t K,
    int64_t N, int64_t numel) {
  int64_t thread_idx = blockIdx.x * blockDim.x + threadIdx.x;
  int64_t e = (thread_idx / K) % E;
  int64_t k = thread_idx % K;

  if (thread_idx < numel) {
    int64_t idx = index_data[e];

    if (count_data[thread_idx] > 0) {
      out_data[idx * K + k] /= count_data[idx * K + k];
    }
  }
}

torch::Tensor segment_mean_cuda_forward(
    torch::Tensor x, torch::Tensor index, int64_t N) {
  // check inputs
  TORCH_CHECK(x.device().is_cuda(), "x must be CUDA tensor");
  TORCH_CHECK(index.device().is_cuda(), "index must be CUDA tensor");
  TORCH_CHECK_INDEX(
      index.dim() == 1, "index dimension should be 1, but got ", index.dim());
  TORCH_CHECK_INDEX(
      x.size(0) == index.size(0),
      "fisrt dimension of x and index should be same");
  // only support float Tensor
  TORCH_CHECK_TYPE(
      x.scalar_type() == c10::ScalarType::Float, "x should be float Tensor")
  cudaSetDevice(x.get_device());
  x = x.contiguous();
  index = index.contiguous();

  auto sizes = x.sizes().vec();
  sizes[0] = N > *index.max().cpu().data_ptr<int64_t>()
                 ? N
                 : *index.max().cpu().data_ptr<int64_t>();
  torch::Tensor out = torch::empty(sizes, x.options());
  // TORCH_CHECK(out.device().is_cuda(), "out must be CUDA tensor");
  torch::Tensor arg_out = torch::full_like(out, 0, index.options());
  int64_t *arg_out_data = arg_out.data_ptr<int64_t>();
  if (x.numel() == 0) {
    out.fill_(0);
    return out;
  }

  out.fill_(0);
  auto E = x.size(0);
  auto K = x.numel() / x.size(0);
  auto stream = at::cuda::getCurrentCUDAStream();

  // AT_DISPATCH_ALL_TYPES(x.scalar_type(), "__ops_name",  [&] {
  using scalar_t = float;  // temporary usage, delete later
  auto x_data = x.data_ptr<scalar_t>();
  auto out_data = out.data_ptr<scalar_t>();
  auto index_data = index.data_ptr<int64_t>();

  torch::Tensor count = torch::full_like(out, 0.0, x.options());
  scalar_t *count_data = count.data_ptr<scalar_t>();

  segment_mean_cuda_forward_kernel<scalar_t>
      <<<BLOCKS(x.numel()), THREADS, 0, stream>>>(
          x_data, index_data, out_data, count_data, E, K, N, x.numel());

  arg_segment_mean_cuda_forward_kernel<scalar_t>
      <<<BLOCKS(x.numel()), THREADS, 0, stream>>>(
          x_data, index_data, out_data, arg_out_data, count_data, E, K, N,
          x.numel());
  // });

  return out;
}
