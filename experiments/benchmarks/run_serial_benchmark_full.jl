using Distances
using Lazy
using IterTools
using FileIO
using AnomalyDetection
using DataStructures

algorithms = ["IsoForest"]

isoforest = true
include("isolation_forest.jl")

loda_path = "../dataset_analysis/tsne_2D-data"
host = gethostname()
#master path where data will be stored
if host == "vit"
	export_path = "/home/vit/vyzkum/anomaly_detection/data/benchmarks/tsne_2D-allanomalies/data" 
elseif host == "axolotl.utia.cas.cz"
	export_path = "/home/skvara/work/anomaly_detection/data/benchmarks/tsne_2D-allanomalies/data"
end
include("parallel_utils.jl")

iteration = (size(ARGS,1) >0) ? parse(Int64, ARGS[1]) : 1
nhdims = 1

datasets = @>> readdir(loda_path) filter(s -> isdir(joinpath(loda_path,s))) filter(!(s -> s in ["url", "gisette", "persistent-connection"]))

map(x -> runexperiments(x[1], iteration, x[2], nhdims),
	product(datasets, algorithms))
