###########################
### general NN settings ###
###### run settings #######
hiddendim = 16
latentdim = 8
activation = Flux.relu
verbfit = false
batchsizes = [256]
###############################

"""
	save_io(path, params, ascore, labels, algo_name)

Saves an algorithm output and input - params and anomaly scores.
"""
function save_io(path, params, ascore, labels, loss, algo_name, nnparams)
	mkpath(path)
	FileIO.save(joinpath(path,"io.jld"), "params", params, "anomaly_score", ascore, 
		"labels", labels, "loss", loss, "algorithm", algo_name, "NN_params", nnparams)   
end

function get_data(dataset_name, iteration)
	# settings
	# ratio of training to all data
	alpha = 0.8 
	# easy/medium/hard/very_hard problem based on similarity of anomalous measurements to normal
	# some datasets dont have easy difficulty anomalies
	if dataset_name in ["madelon", "gisette"]
		difficulty = "medium"
	elseif dataset_name in ["vertebral-column"]
		difficulty = "hard"
	else
		difficulty = "easy" 
	end
	# ratio of anomalous to normal data
	frequency = 0.05 
	# low/high - should anomalies be clustered or not
	variation = "low"
	# random seed 
	seed = Int64(iteration)

	# this might fail for url
	basicset = AnomalyDetection.Basicset(joinpath(loda_path, dataset_name))
	trdata, tstdata, clusterdness = AnomalyDetection.makeset(basicset, alpha, difficulty, frequency, variation,
		seed = seed)
	return trdata, tstdata	
end

##########
### AE ###
##########

"""
	trainAE(path, dataset_name, iteration)

Trains an autoencoder.
"""
function trainAE(path, dataset_name, iteration)
	# get the dataset
	trdata, tstdata = get_data(dataset_name, iteration)
	trX = trdata.data;
	trY = trdata.labels;
	tstX = tstdata.data;
	tstY = tstdata.labels;
	indim, trN = size(trX[:,trY.==0])

	# over these parameters will be iterated
	AEparams = Dict(
			"L" => batchsizes # batchsize
			)
	
	# set params to be saved later
	params = Dict(
			# set problem dimensions
		"indim" => indim,
		"hiddendim" => hiddendim,
		"latentdim" => latentdim,
		# model constructor parameters
		"esize" => [indim; hiddendim; hiddendim; latentdim], # encoder architecture
		"dsize" => [latentdim; hiddendim; hiddendim; indim], # decoder architecture
		"L" => 0, # batchsize, will be iterated over
		"threshold" => 0, # classification threshold, is recomputed when calling fit!
		"contamination" => size(trY[trY.==1],1)/size(trY[trY.==0],1), # to set the decision threshold
		"iterations" => 5000,
		"cbit" => 1000, # when callback is printed
		"verbfit" => verbfit, 
		"activation" => string(activation),
		"rdelta" => 1e-5, # reconstruction error threshold when training is stopped
		"Beta" => 1.0, # for automatic threshold computation, in [0, 1] 
		# 1.0 = tight around normal samples
		"tracked" => true # do you want to store training progress?
		# it can be later retrieved from model.traindata
		)

	# also, if batchsize is too large, add a batchsize param of the data size
	poplast = false
	if minimum(AEparams["L"]) > trN
		push!(AEparams["L"], trN)
		poplast = true
	end

	for L in AEparams["L"]
		if L > size(trX,2)
			continue
		end
		params["L"] = L
		# setup the model
		model = AnomalyDetection.AEmodel(params["esize"], params["dsize"], params["L"], params["threshold"], 
			params["contamination"], params["iterations"], params["cbit"], params["verbfit"], 
			activation = activation, rdelta = params["rdelta"], tracked = params["tracked"],
			Beta = params["Beta"])
		# train the model
		AnomalyDetection.fit!(model, trX, trY)
		# get anomaly scores on testing data
		ascore = [Flux.Tracker.data(AnomalyDetection.anomalyscore(model, tstX[:,i]))
    		for i in 1:size(tstX,2)];
    	# save anomaly scores, labels and settings
    	pname = joinpath(path, string("$(iteration)/AE_", L))
    	save_io(pname, params, ascore, tstY, model.traindata, "AE", Flux.params(model.ae))
	end

	# delete the last element of the 
	if poplast
		pop!(AEparams["L"])
	end

	println("AE training on $(joinpath(path, string(iteration))) finished!")
end

###########
### VAE ###
###########	

"""
	trainVAE(path, dataset_name, iteration)

Trains a VAE and classifies training data in path..
"""
function trainVAE(path, dataset_name, iteration)
	# load data
	trdata, tstdata = get_data(dataset_name, iteration)	
	trX = trdata.data;
	trY = trdata.labels;
	tstX = tstdata.data;
	tstY = tstdata.labels;
	indim, trN = size(trX[:,trY.==0])

	# this will be iterated over
	VAEparams = Dict(
		"L" => batchsizes,
		"lambda" => [10.0^i for i in 0:-1:-4]
		)

	# also, if batchsize is too large, add a batchsize param of the data size
	poplast = false
	if minimum(VAEparams["L"]) > trN
		push!(VAEparams["L"], trN)
		poplast = true
	end

	# set params to be saved later
	params = Dict(
		# set problem dimensions
		"indim" => indim,
		"hiddendim" => hiddendim,
		"latentdim" => latentdim,
		# model constructor parameters
		"esize" => [indim; hiddendim; hiddendim; latentdim*2], # encoder architecture
		"dsize" => [latentdim; hiddendim; hiddendim; indim], # decoder architecture
		"lambda" => 1, # KLD weight in loss function
		"L" => 0, # batchsize, will be iterated over
		"threshold" => 0, # classification threshold, is recomputed when calling fit!
		"contamination" => size(trY[trY.==1],1)/size(trY[trY.==0],1), # to set the decision threshold
		"iterations" => 10000,
		"cbit" => 5000, # when callback is printed
		"verbfit" => verbfit, 
		"M" => 1, # number of samples for reconstruction error, set higher for classification
		"activation" => string(activation),
		"rdelta" => 1e-5, # reconstruction error threshold when training is stopped
		"Beta" => 1.0, # for automatic threshold computation, in [0, 1] 
		# 1.0 = tight around normal samples
		"tracked" => true # do you want to store training progress?
		# it can be later retrieved from model.traindata
		)
	
	for L in VAEparams["L"], lambda in VAEparams["lambda"]
		if L > trN
			continue
		end
		params["L"] = L
		params["lambda"] = lambda

		# setup the model
		model = AnomalyDetection.VAEmodel(params["esize"], params["dsize"], params["lambda"],	params["threshold"], 
			params["contamination"], params["iterations"], params["cbit"], params["verbfit"],
			params["L"], M = params["M"], activation = activation, rdelta = params["rdelta"], 
			Beta = params["Beta"], tracked = params["tracked"])
		# train the model
		AnomalyDetection.fit!(model, trX, trY)
		# get anomaly scores on testing data
		params["M"] = 5
		model.M = params["M"] # set higher for stable classification
		ascore = [Flux.Tracker.data(AnomalyDetection.anomalyscore(model, tstX[:,i]))
    		for i in 1:size(tstX,2)];
    	# save anomaly scores, labels and settings
    	pname = joinpath(path, string("$(iteration)/VAE_$(L)_$(lambda)"))
    	save_io(pname, params, ascore, tstY, model.traindata, "VAE", Flux.params(model.vae))
	end

	# delete the last element of the 
	if poplast
		pop!(VAEparams["L"])
	end

	println("VAE training on $(joinpath(path, string(iteration))) finished!")
end

############
### sVAE ###
############	

"""
	trainsVAE(path, dataset_name, iteration)

Trains a sVAE and classifies training data in path..
"""
function trainsVAE(path, dataset_name, iteration)
	# load data
	trdata, tstdata = get_data(dataset_name, iteration)
	trX = trdata.data;
	trY = trdata.labels;
	tstX = tstdata.data;
	tstY = tstdata.labels;
	indim, trN = size(trX[:,trY.==0])

	# this will be iterated over
	sVAEparams = Dict(
	"L" => batchsizes,
	"lambda" => push!([10.0^i for i in -2:2], 0.0), # data fit error term in loss
	"alpha" => linspace(0,1,5) # data fit error term in anomaly score
	)

	# set params to be saved later
	params = Dict(
		# set problem dimensions
		"indim" => indim,
		"hiddendim" => hiddendim,
		"latentdim" => latentdim,
		# model constructor parameters
		"ensize" => [indim; hiddendim; hiddendim; latentdim*2], # encoder architecture
		"decsize" => [latentdim; hiddendim; hiddendim; indim], # decoder architecture
		"dissize" => [indim + latentdim; hiddendim; hiddendim; 1], # discriminator architecture
		"lambda" => 1, # data error weight for training
		"threshold" => 0, # classification threshold, is recomputed when calling fit!
		"contamination" => size(trY[trY.==1],1)/size(trY[trY.==0],1), # to set the decision threshold
		"iterations" => 10000,
		"cbit" => 5000, # when callback is printed
		"verbfit" => verbfit, 
		"L" => 0, # batchsize, will be iterated over
		"M" => 1, # number of samples for reconstruction error, set higher for classification
		"activation" => string(activation),
		"rdelta" => 1e-5, # reconstruction error threshold when training is stopped
		"alpha" => 0.5, # data error term for classification
		"Beta" => 1.0, # for automatic threshold computation, in [0, 1] 
		# 1.0 = tight around normal samples
		"tracked" => true, # do you want to store training progress?
		# it can be later retrieved from model.traindata
		"xsigma" => 1.0 # static estimate of data variance
		)

	# also, if batchsize is too large, add a batchsize param of the data size
	poplast = false
	if minimum(sVAEparams["L"]) > trN
		push!(sVAEparams["L"], trN)
		poplast = true
	end
	
	for L in sVAEparams["L"], lambda in sVAEparams["lambda"]
		if L > trN
			continue
		end
		params["L"] = L
		params["lambda"] = lambda

		# setup the model
		model = AnomalyDetection.sVAEmodel(params["ensize"], params["decsize"], params["dissize"],
		 params["lambda"],	params["threshold"], params["contamination"], 
		 params["iterations"], params["cbit"], params["verbfit"], params["L"], 
		 M = params["M"], activation = activation, rdelta = params["rdelta"], 
			tracked = params["tracked"], Beta = params["Beta"], xsigma = params["xsigma"])
		# train the model
		AnomalyDetection.fit!(model, trX, trY)
		# get anomaly scores on testing data
		params["M"] = 5
		model.M = params["M"] # set higher for stable classification
		for alpha in sVAEparams["alpha"]
			params["alpha"] = alpha
			model.alpha = alpha
			ascore = [Flux.Tracker.data(AnomalyDetection.anomalyscore(model, tstX[:,i]))
	    		for i in 1:size(tstX,2)];
	    	
	    	# save anomaly scores, labels and settings
	    	pname = joinpath(path, string("$(iteration)/sVAE_$(L)_$(lambda)_$(alpha)"))
	    	save_io(pname, params, ascore, tstY, model.traindata, "sVAE", Flux.params(model.svae))
	    end
	end

	# delete the last element of batchsizes
	if poplast
	 	pop!(sVAEparams["L"])
	end

	println("sVAE training on $(joinpath(path, string(iteration))) finished!")
end

###########
### GAN ###
###########

"""
	trainGAN(path, dataset_name, iteration)

Trains a GAN and classifies training data in path.
"""
function trainGAN(path, dataset_name, iteration)
	# load data
	trdata, tstdata = get_data(dataset_name, iteration)
	trX = trdata.data;
	trY = trdata.labels;
	tstX = tstdata.data;
	tstY = tstdata.labels;
	indim, trN = size(trX[:,trY.==0])
	
	GANparams = Dict(
	"L" => batchsizes, # batchsize
	"lambda" => linspace(0,1,5) # weight of reconstruction error in anomalyscore
	)

	# set params to be saved later
	params = Dict(
			# set problem dimensions
		"indim" => indim,
		"hiddendim" => hiddendim,
		"latentdim" => latentdim,
		# model constructor parameters
		"gsize" => [latentdim; hiddendim; hiddendim; indim], # generator architecture
		"dsize" => [indim; hiddendim; hiddendim; 1], # discriminator architecture
		"threshold" => 0, # classification threshold, is recomputed when calling fit!
		"contamination" => size(trY[trY.==1],1)/size(trY[trY.==0],1), # to set the decision threshold
		"lambda" => 0.5, # anomaly score rerr weight
		"L" => 0, # batchsize
		"iterations" => 10000,
		"cbit" => 5000, # when callback is printed
		"verbfit" => verbfit, 
		"pz" => string(randn),
		"activation" => string(activation),
		"rdelta" => 1e-5, # reconstruction error threshold when training is stopped
		"Beta" => 1.0, # for automatic threshold computation, in [0, 1] 
		# 1.0 = tight around normal samples
		"tracked" => true # do you want to store training progress?
		# it can be later retrieved from model.traindata
		)

	# also, if batchsize is too large, add a batchsize param of the data size
	poplast = false
	if minimum(GANparams["L"]) > trN
		push!(GANparams["L"], trN)
		poplast = true
	end

	for L in GANparams["L"]
		if L > trN
			continue
		end

		# setup the model
		model = AnomalyDetection.GANmodel(params["gsize"], params["dsize"], params["lambda"], params["threshold"], 
			params["contamination"], L, params["iterations"], params["cbit"], 
			params["verbfit"], pz = randn, activation = activation, rdelta = params["rdelta"], 
			tracked = params["tracked"], Beta = params["Beta"])
		# train the model
		AnomalyDetection.fit!(model, trX, trY)
		for lambda in GANparams["lambda"]
			params["lambda"] = lambda
			model.lambda = lambda
			# get anomaly scores on testing data
			ascore = [Flux.Tracker.data(AnomalyDetection.anomalyscore(model, tstX[:,i]))
	    		for i in 1:size(tstX,2)];
	    	# save anomaly scores, labels and settings
	    	pname = joinpath(path, string("$(iteration)/GAN_$(L)_$(lambda)"))
    		save_io(pname, params, ascore, tstY, model.traindata, "GAN", Flux.params(model.gan))
	    end
	end

	# delete the last element of batchsizes
	if poplast
		pop!(GANparams["L"])
	end

	println("GAN training on $(joinpath(path, string(iteration))) finished!")
end

#############
### fmGAN ###
#############


"""
	trainfmGAN(path, mode)

Trains a fmGAN and classifies training data in path..
"""
function trainfmGAN(path, dataset_name, iteration)
	# load data
	trdata, tstdata = get_data(dataset_name, iteration)
	trX = trdata.data;
	trY = trdata.labels;
	tstX = tstdata.data;
	tstY = tstdata.labels;
	indim, trN = size(trX[:,trY.==0])
	
	fmGANparams = Dict(
	"L" => batchsizes, # batchsize
	"lambda" => linspace(0,1,5), # weight of reconstruction error in anomalyscore
	"alpha" => push!([10.0^i for i in -2:2], 0.0) 
	)

	# set params to be saved later
	params = Dict(
			# set problem dimensions
		"indim" => indim,
		"hiddendim" => hiddendim,
		"latentdim" => latentdim,
		# model constructor parameters
		"gsize" => [latentdim; hiddendim; hiddendim; indim], # generator architecture
		"dsize" => [indim; hiddendim; hiddendim; 1], # discriminator architecture
		"threshold" => 0, # classification threshold, is recomputed when calling fit!
		"contamination" => size(trY[trY.==1],1)/size(trY[trY.==0],1), # to set the decision threshold
		"lambda" => 0.5, # anomaly score rerr weight
		"L" => 0, # batchsize
		"iterations" => 10000,
		"cbit" => 5000, # when callback is printed
		"verbfit" => verbfit, 
		"pz" => string(randn),
		"activation" => string(activation),
		"rdelta" => 1e-5, # reconstruction error threshold when training is stopped
		"alpha" => 0.5, # weight of discriminator score in generator loss training
		"Beta" => 1.0, # for automatic threshold computation, in [0, 1] 
		# 1.0 = tight around normal samples
		"tracked" => true # do you want to store training progress?
		# it can be later retrieved from model.traindata
		)

	# also, if batchsize is too large, add a batchsize param of the data size
	poplast = false
	if minimum(fmGANparams["L"]) > trN
		push!(fmGANparams["L"], trN)
		poplast = true
	end

	for L in fmGANparams["L"], alpha in fmGANparams["alpha"]
		if L > trN
			continue
		end
		
		# setup the model
		model = AnomalyDetection.fmGANmodel(params["gsize"], params["dsize"], params["lambda"], params["threshold"], 
			params["contamination"], L, params["iterations"], params["cbit"], 
			params["verbfit"], pz = randn, activation = activation, rdelta = params["rdelta"], 
			tracked = params["tracked"], Beta = params["Beta"], alpha = alpha)
		# train the model
		AnomalyDetection.fit!(model, trX, trY)
		for lambda in fmGANparams["lambda"]
			params["lambda"] = lambda
			model.lambda = lambda
			# get anomaly scores on testing data
			ascore = [Flux.Tracker.data(AnomalyDetection.anomalyscore(model, tstX[:,i]))
	    		for i in 1:size(tstX,2)];
	    	# save anomaly scores, labels and settings
	    	pname = joinpath(path, string("$(iteration)/fmGAN_$(L)_$(lambda)_$(alpha)"))
	    	save_io(pname, params, ascore, tstY, model.traindata, "fmGAN", Flux.params(model.fmgan))
	    end
	end

	# delete the last element of batchsizes
	if poplast
		pop!(fmGANparams["L"])
	end

	println("fmGAN training on $(joinpath(path, string(iteration))) finished!")
end

###########
### kNN ###
###########

"""
	trainkNN(path, dataset_name, mode)

Trains a kNN and classifies training data in path.
"""
function trainkNN(path, dataset_name, mode)
	# load data
	trdata, tstdata = get_data(dataset_name, iteration)
	trX = trdata.data;
	trY = trdata.labels;
	tstX = tstdata.data;
	tstY = tstdata.labels;
	indim, trN = size(trX)
	
	# set params to be saved later
	params = Dict(
		"k" => 1,
		"metric" => string(Euclidean()),
		"weights" => "distance",
		"threshold" => 0.5,
		"reduced_dim" => true,
		)

	kvec = Int.(round.(linspace(1, 2*sqrt(trN), 5)))

	@parallel for k in kvec 
		params["k"] = k
		# setup the model
		model = AnomalyDetection.kNN(params["k"], metric = Euclidean(), weights = params["weights"], 
			threshold = params["threshold"], reduced_dim = params["reduced_dim"])

		# train the model
		AnomalyDetection.fit!(model, trX, trY)
		# get anomaly scores on testing data
		ascore = [Flux.Tracker.data(AnomalyDetection.anomalyscore(model, tstX[:,i]))
    		for i in 1:size(tstX,2)];
		# save anomaly scores, labels and settings
    	pname = joinpath(path, string("$(iteration)/kNN_$(k)"))
    	save_io(pname, params, ascore, tstY, Dict{Any, Any}(), "kNN", [])
    end

	println("kNN training on $(joinpath(path, string(iteration))) finished!")
end
