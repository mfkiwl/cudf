/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <strings/count_matches.hpp>
#include <strings/regex/dispatcher.hpp>
#include <strings/regex/regex.cuh>
#include <strings/utilities.hpp>

#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/strings/detail/strings_column_factories.cuh>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/strings/findall.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/strings_column_view.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/for_each.h>

namespace cudf {
namespace strings {
namespace detail {

using string_index_pair = thrust::pair<const char*, size_type>;

namespace {

/**
 * @brief This functor handles extracting matched strings by applying the compiled regex pattern
 * and creating string_index_pairs for all the substrings.
 */
template <int stack_size>
struct findall_fn {
  column_device_view const d_strings;
  reprog_device prog;
  offset_type const* d_offsets;
  string_index_pair* d_indices;

  __device__ void operator()(size_type const idx)
  {
    if (d_strings.is_null(idx)) { return; }
    auto const d_str = d_strings.element<string_view>(idx);

    auto d_output        = d_indices + d_offsets[idx];
    size_type output_idx = 0;

    int32_t begin = 0;
    int32_t end   = d_str.length();
    while ((begin < end) && (prog.find<stack_size>(idx, d_str, begin, end) > 0)) {
      auto const spos = d_str.byte_offset(begin);  // convert
      auto const epos = d_str.byte_offset(end);    // to bytes

      d_output[output_idx++] = string_index_pair{d_str.data() + spos, (epos - spos)};

      begin = end + (begin == end);
      end   = d_str.length();
    }
  }
};

struct findall_dispatch_fn {
  reprog_device d_prog;

  template <int stack_size>
  std::unique_ptr<column> operator()(column_device_view const& d_strings,
                                     size_type total_matches,
                                     offset_type const* d_offsets,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    rmm::device_uvector<string_index_pair> indices(total_matches, stream);

    thrust::for_each_n(rmm::exec_policy(stream),
                       thrust::make_counting_iterator<size_type>(0),
                       d_strings.size(),
                       findall_fn<stack_size>{d_strings, d_prog, d_offsets, indices.data()});

    return make_strings_column(indices.begin(), indices.end(), stream, mr);
  }
};

}  // namespace

//
std::unique_ptr<column> findall_record(
  strings_column_view const& input,
  std::string const& pattern,
  regex_flags const flags,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource())
{
  auto const strings_count = input.size();
  auto const d_strings     = column_device_view::create(input.parent(), stream);

  // compile regex into device object
  auto const d_prog =
    reprog_device::create(pattern, flags, get_character_flags_table(), strings_count, stream);

  // Create lists offsets column
  auto offsets   = count_matches(*d_strings, *d_prog, stream, mr);
  auto d_offsets = offsets->mutable_view().data<offset_type>();

  // Compute null output rows
  auto [null_mask, null_count] = cudf::detail::valid_if(
    d_offsets,
    d_offsets + strings_count,
    [] __device__(auto const v) { return v > 0; },
    stream,
    mr);

  auto const valid_count = strings_count - null_count;
  // Return an empty lists column if there are no valid rows
  if (valid_count == 0) {
    return make_lists_column(0,
                             make_empty_column(type_to_id<offset_type>()),
                             make_empty_column(type_id::STRING),
                             0,
                             rmm::device_buffer{},
                             stream,
                             mr);
  }

  // Convert counts into offsets
  thrust::exclusive_scan(
    rmm::exec_policy(stream), d_offsets, d_offsets + strings_count + 1, d_offsets);

  // Create indices vector with the total number of groups that will be extracted
  auto const total_matches =
    cudf::detail::get_value<size_type>(offsets->view(), strings_count, stream);

  auto strings_output = regex_dispatcher(
    *d_prog, findall_dispatch_fn{*d_prog}, *d_strings, total_matches, d_offsets, stream, mr);

  // Build the lists column from the offsets and the strings
  return make_lists_column(strings_count,
                           std::move(offsets),
                           std::move(strings_output),
                           null_count,
                           std::move(null_mask),
                           stream,
                           mr);
}

}  // namespace detail

// external API

std::unique_ptr<column> findall_record(strings_column_view const& input,
                                       std::string const& pattern,
                                       regex_flags const flags,
                                       rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::findall_record(input, pattern, flags, rmm::cuda_stream_default, mr);
}

}  // namespace strings
}  // namespace cudf
