[![PyPI](https://img.shields.io/pypi/v/vehicle-lang)](https://pypi.org/project/vehicle-lang/)
![GitHub tag (latest by date)](https://img.shields.io/github/v/tag/vehicle-lang/vehicle)
[![GitHub Workflow Status](https://github.com/vehicle-lang/vehicle/actions/workflows/ci.yml/badge.svg)](https://github.com/vehicle-lang/vehicle/actions/workflows/ci.yml)
[![readthedocs status](https://readthedocs.org/projects/vehicle-lang/badge/?version=latest)](https://vehicle-lang.readthedocs.io/en/latest/)
[![pre-commit.ci status](https://results.pre-commit.ci/badge/github/vehicle-lang/vehicle/dev.svg)](https://results.pre-commit.ci/latest/github/vehicle-lang/vehicle/dev)

# Code Explanation
<b>1. Setup Locations<b/>
The first step in the project is to define the locations that need to be visited. These include a central depot and multiple customer locations. Each location is represented by its coordinates in a 2D space.

2. Distance Matrix Calculation
To evaluate the efficiency of different routes, we calculate the distance between each pair of locations. This is done by creating a distance matrix where each entry represents the Euclidean distance between two locations. This matrix helps in assessing the total distance of any given route.

3. Genetic Algorithm Functions
Generate and Create Population:
The genetic algorithm starts by generating an initial population of routes. Each route is a permutation of the locations, representing a possible sequence in which the vehicle might visit the locations. The population is created by randomly shuffling these routes.

Fitness Function:
The fitness function evaluates how good a route is by calculating its total distance using the previously computed distance matrix. A shorter total distance indicates a better (more optimal) route.

Mutation:
Mutation introduces randomness into the population by altering existing routes. Specifically, it involves swapping two locations within a route. This helps in exploring new routes that might lead to better solutions.

Crossover:
Crossover combines parts of two parent routes to create new routes. This process involves selecting a segment of one parent route and filling in the remaining parts from the second parent, preserving as many good traits from both parents as possible.

Genetic Algorithm Execution:
The main genetic algorithm function evolves the population of routes over several generations. It selects the best routes (based on fitness), applies crossover and mutation to generate new routes, and ensures that the best solutions are preserved (elitism). The process continues until the algorithm converges or reaches a predefined number of generations.

4. Visualization
The best route found by the genetic algorithm is visualized using a plotting library. The visualization displays the locations as points and draws lines between them to represent the route. This helps in understanding the route and verifying the solution.

5. Running the Algorithm
To find and visualize the best route, you can adjust parameters such as the size of the population, the number of generations, and the size of the elite group. The algorithm is run with these parameters, and the results are printed and visualized, showing the most efficient route and its total distance.


# Vehicle

Vehicle is a system for embedding logical specifications into neural networks.
At its heart is the Vehicle specification language, a high-level, functional language for writing mathematically-precise specifications for your networks. For example, the following simple
specification says that a network's output should be monotonically increasing with respect to
its third input.

<!-- This must be a direct link, because the same README is used on PyPI -->
![Example specification](https://github.com/vehicle-lang/vehicle/blob/dev/docs/example-spec.png?raw=true)

These specifications can then automatically be compiled down to loss functions to be
used when training your network.
After training, the same specification can be compiled down to low-level neural network verifiers such as Marabou which either prove that the specification holds or produce a counter-example. Such a proof is far better than simply testing, as you can prove that
the specification holds for _all_ inputs.
Verified specifications can also be exported to interactive theorem provers (ITPs)
such as Agda.
This in turn allows for the formal verification of larger software systems
that use neural networks as subcomponents.
The generated ITP code is tightly linked to the actual deployed network, so changes
to the network will result in errors when checking the larger proof.

## Documentation

- [User manual](https://vehicle-lang.readthedocs.io/en/latest/)
- [Tutorial](https://vehicle-lang.github.io/tutorial/)

## Examples

Each of the following examples comes with an explanatory README file:

- [ACAS Xu](https://github.com/vehicle-lang/vehicle/blob/dev/examples/acasXu/) - The complete specification of the ACAS Xu collision avoidance system from the [Reluplex paper](https://arxiv.org/abs/1702.01135) in a single file.

- [Car controller](https://github.com/vehicle-lang/vehicle/blob/dev/examples/windController/) - A neural network controller that is formally proven to always keep a simple model of a car on the road in the face of noisy sensor data and an unpredictable cross-wind.

- [MNIST robustness](https://github.com/vehicle-lang/vehicle/blob/dev/examples/mnist-robustness/) - A classifier for the MNIST dataset that is proven to be robust around the images in the dataset.

In addition to the above, further examples of specifications can be found in the [test suite](https://github.com/vehicle-lang/vehicle/tree/dev/test/specs)
and the corresponding output of the Vehicle compiler can be found [here](https://github.com/vehicle-lang/vehicle/tree/dev/test/Test/Compile/Golden).

## Support

If you are interested in adding support for a particular format/verifier/ITP
then open an issue on the [Issue Tracker](https://github.com/wenkokke/vehicle/issues)
to discuss it with us.

#### Neural network formats

- [ONNX](https://onnx.ai/)

#### Dataset formats

- [IDX](http://yann.lecun.com/exdb/mnist/)

#### Verifier backends

- [Marabou](https://github.com/NeuralNetworkVerification/Marabou)

#### Interactive Theorem Prover backends

- [Agda](https://agda.readthedocs.io/)

## Related papers

- [Vehicle tool paper](https://arxiv.org/abs/2401.06379)
- [Vehicle's type checker (in CPP'23)](https://laiv.uk/wp-content/uploads/2022/12/vehicle.pdf)
- [Vehicle's compilation to verifier queries](https://arxiv.org/abs/2402.01353)
