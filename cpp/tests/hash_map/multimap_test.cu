/*
 * Copyright (c) 2018-2021, NVIDIA CORPORATION.
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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/cudf_gtest.hpp>

#include <hash/concurrent_unordered_multimap.cuh>
#include <hash/hash_allocator.cuh>

#include <rmm/cuda_stream_view.hpp>

#include <gtest/gtest.h>

#include <limits>

// This is necessary to do a parametrized typed-test over multiple template
// arguments
template <typename Key, typename Value>
struct KeyValueTypes {
  using key_type   = Key;
  using value_type = Value;
};

// A new instance of this class will be created for each *TEST(MultimapTest,
// ...) Put all repeated stuff for each test here
template <class T>
class MultimapTest : public cudf::test::BaseFixture {
 public:
  using key_type   = typename T::key_type;
  using value_type = typename T::value_type;
  using size_type  = int;

  using multimap_type =
    concurrent_unordered_multimap<key_type,
                                  value_type,
                                  size_type,
                                  std::numeric_limits<key_type>::max(),
                                  std::numeric_limits<value_type>::max(),
                                  default_hash<key_type>,
                                  equal_to<key_type>,
                                  default_allocator<thrust::pair<key_type, value_type>>>;

  std::unique_ptr<multimap_type, std::function<void(multimap_type*)>> the_map;

  const key_type unused_key     = std::numeric_limits<key_type>::max();
  const value_type unused_value = std::numeric_limits<value_type>::max();

  const size_type size;

  MultimapTest(const size_type hash_table_size = 100)
    : the_map(multimap_type::create(hash_table_size)), size(hash_table_size)
  {
    rmm::cuda_stream_default.synchronize();
  }

  ~MultimapTest() override {}
};

// Google Test can only do a parameterized typed-test over a single type, so we
// have to nest multiple types inside of the KeyValueTypes struct above
// KeyValueTypes<type1, type2> implies key_type = type1, value_type = type2
// This list is the types across which Google Test will run our tests
using Implementations = ::testing::Types<KeyValueTypes<int, int>,
                                         KeyValueTypes<int, long long>,
                                         KeyValueTypes<int, unsigned long long>,
                                         KeyValueTypes<unsigned long long, int>,
                                         KeyValueTypes<unsigned long long, long long>,
                                         KeyValueTypes<unsigned long long, unsigned long long>>;

TYPED_TEST_SUITE(MultimapTest, Implementations);

TYPED_TEST(MultimapTest, InitialState)
{
  using key_type   = typename TypeParam::key_type;
  using value_type = typename TypeParam::value_type;

  auto begin = this->the_map->begin();
  auto end   = this->the_map->end();
  EXPECT_NE(begin, end);
}
