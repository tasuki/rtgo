# TODO

- [ ] Benchmark KataGo Eigen with and without AVX2 on an AVX2-capable CPU.
  - Use otherwise identical KataGo v1.16.4 Release builds and the current
    `kata1-b6c96-s175395328-d26788732.txt.gz` network.
  - Keep the current single-visit analysis settings; warm up both engines and
    evaluate the same representative positions repeatedly.
  - Measure inference latency and throughput, including concurrent bot requests.
    Measure end-to-end bot response time separately to account for the 250ms
    polling interval.
  - Record the CPU, compiler, build flags, and results. Use the measurements to
    decide whether to offer an optional AVX2 build; retain a portable build for
    CPUs without AVX2 support.
