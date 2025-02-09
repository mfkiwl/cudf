/*
 * Copyright (c) 2021-2022, NVIDIA CORPORATION.
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

#include <benchmarks/common/generate_input.hpp>
#include <benchmarks/fixture/benchmark_fixture.hpp>
#include <benchmarks/synchronization/synchronization.hpp>

#include <cudf/dictionary/encode.hpp>
#include <cudf/reduction.hpp>
#include <cudf/types.hpp>
#include <cudf/unary.hpp>

class ReductionDictionary : public cudf::benchmark {
};

template <typename T>
void BM_reduction_dictionary(benchmark::State& state,
                             std::unique_ptr<cudf::reduce_aggregation> const& agg)
{
  const cudf::size_type column_size{static_cast<cudf::size_type>(state.range(0))};

  // int column and encoded dictionary column
  data_profile profile;
  profile.set_null_frequency(std::nullopt);
  profile.set_cardinality(0);
  profile.set_distribution_params<long>(cudf::type_to_id<long>(),
                                        distribution_id::UNIFORM,
                                        (agg->kind == cudf::aggregation::ALL ? 1 : 0),
                                        (agg->kind == cudf::aggregation::ANY ? 0 : 100));
  auto int_table = create_random_table({cudf::type_to_id<long>()}, row_count{column_size}, profile);
  auto number_col = cudf::cast(int_table->get_column(0), cudf::data_type{cudf::type_to_id<T>()});
  auto values     = cudf::dictionary::encode(*number_col);

  cudf::data_type output_dtype = [&] {
    if (agg->kind == cudf::aggregation::ANY || agg->kind == cudf::aggregation::ALL)
      return cudf::data_type{cudf::type_id::BOOL8};
    if (agg->kind == cudf::aggregation::MEAN) return cudf::data_type{cudf::type_id::FLOAT64};
    return cudf::data_type{cudf::type_to_id<T>()};
  }();

  for (auto _ : state) {
    cuda_event_timer timer(state, true);
    auto result = cudf::reduce(*values, agg, output_dtype);
  }
}

#define concat(a, b, c) a##b##c
#define get_agg(op)     concat(cudf::make_, op, _aggregation<cudf::reduce_aggregation>())

// TYPE, OP
#define RBM_BENCHMARK_DEFINE(name, type, aggregation)                       \
  BENCHMARK_DEFINE_F(ReductionDictionary, name)(::benchmark::State & state) \
  {                                                                         \
    BM_reduction_dictionary<type>(state, get_agg(aggregation));             \
  }                                                                         \
  BENCHMARK_REGISTER_F(ReductionDictionary, name)                           \
    ->UseManualTime()                                                       \
    ->Arg(10000)      /* 10k */                                             \
    ->Arg(100000)     /* 100k */                                            \
    ->Arg(1000000)    /* 1M */                                              \
    ->Arg(10000000)   /* 10M */                                             \
    ->Arg(100000000); /* 100M */

#define REDUCE_BENCHMARK_DEFINE(type, aggregation) \
  RBM_BENCHMARK_DEFINE(concat(type, _, aggregation), type, aggregation)

REDUCE_BENCHMARK_DEFINE(int32_t, all);
REDUCE_BENCHMARK_DEFINE(float, all);
REDUCE_BENCHMARK_DEFINE(int32_t, any);
REDUCE_BENCHMARK_DEFINE(float, any);
REDUCE_BENCHMARK_DEFINE(int32_t, min);
REDUCE_BENCHMARK_DEFINE(float, min);
REDUCE_BENCHMARK_DEFINE(int32_t, max);
REDUCE_BENCHMARK_DEFINE(float, max);
REDUCE_BENCHMARK_DEFINE(int32_t, mean);
REDUCE_BENCHMARK_DEFINE(float, mean);
