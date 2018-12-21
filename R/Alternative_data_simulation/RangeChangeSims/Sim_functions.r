#################################################

require(reshape2)
require(lme4)

################################################# 
#GENERIC FUNCTIONS 

#################################################

#small functions

# takes a vector and returns whether the length is greater than 0
occurrence <- function(x) length(x) > 0 

visit_site_Ntimes <- function(i, times, true_data){
  replicate(times, recording_visit(true_data[i,], p_obs=attr(true_data, "p_detect")))
}

visit_these_sites <- function(sites_visited, true_data){
  sapply(sites_visited, function(i) recording_visit(true_data[i,], p_obs=attr(true_data, "p_detect")))
}

LenUniq <- function(x) length(unique(x)) #for calculating the list length from a list of species (allows duplicates, which are ignored)

one_to_two_tail <- function(p) ifelse(p<0.5, p*2, (1-p)*2)

median_occ <- function(true_data){
  # returns the column number of true_data corresponding to the species with the median distributions size (excluding the focal)
  # there's no which.median() function to this effectively creates that functionality
  x <- colSums(true_data)[-1]
  #x[order(x)] #lists species in increasing order
  name <- names(x[order(x)][ceiling(length(x)/2)])
  return(1 + as.numeric(gsub('spp','',name))) # add 1 because of the focal species
}

##################################################

#create data function

create_data <- function(nSites=500, nSpecies=25, pFocal=list(Occ=0.5, DetP=0.5), ONR=F, bsh1=2, bsh2=2){
    # 3 December: as 'old' above, except
    # a) nonfocal species are defined by a beta distribution (occupancy & detectability)
    # b) includes an attribute of the true detection probability for each species
    # 24 January: I fixed some inconsistency in the use of nSpecies
    #   For simplicity, the User-defined number of species is the number of NON-FOCALS
    #   I've also changed the shape of the interspecific occupancy distribution to be symmetrical around 0.5
    #   Although [mean occupancy]<<0.5 for most groups, this high number is necessary to generate enough 'global benchmarks'
    #   (i.e. species that are common enough everywhere to give Frescalo a decent change of generating neighbourhoods)
    #   And added an optional ONR (Occupancy Abundance(Number) Relationship) - the N follows McGill
    #   When False (the default) there is NO correlation between occupancy and detectability (abundance)
    #   When True, there is a perfect correlation between Detectability and Occupancy
    # 22 January: I further modified the detectability function, following consultation with Mark Hill.
    #   The function descrbed in create_data_3 (the last current version) is for a survey of intensity=1
    #   For bryophytes, surveying a hectad to this intensity takes 8 days!
    #   In Mark's concept, the pool of possible species being detected at a site is infinite,
    #       but the 'expected number of species from a complete survey (intensity >> 1) is known
    #   I want to simulate a standard visit, which is much less intense, but where the most detectable species are highly likely to be recorded
    #   I tried using an exponential decay function but it was much too steep.  
    # 9 April: pFocal separated into Occupancy & probability of detection
    
    # first define the vector of presence-absence for the focal species
    focal <- rbinom(n=nSites, size=1, prob=pFocal$Occ)
    
    HillP <- function(nSp, pse=1, a=2.005, b=-2.545, S=0.3){
        # generates a detectability decay curve as per Mark hill's Frescalo paper
        # under the default settings, the sppSVS has an 89% detection prob, the least detectable 16%.
        # the median detectability is 46%
        # this decay curve is close to linear
        R <- 1:nSp/(pse*nSp)  
        pd <- 1-exp(-S*exp(a+b*R))
    }
    
    p_detect <- HillP(nSpecies)
    if(ONR) p_occ <- p_detect
    else p_occ <- rbeta(n=nSpecies, bsh1, bsh2)
    
    x <- t(replicate(nSites, rbinom(n=nSpecies, size=1, prob=p_occ)))
    dimnames(x)[[1]] <- paste('site',1:nSites, sep='')
    dimnames(x)[[2]] <- paste('spp',1:nSpecies, sep='')
    x <- cbind(focal, x)
    attr(x,'richness') <- as.numeric(rowSums(x))
    attr(x,'p_detect') <- c(as.numeric(pFocal$DetP), p_detect)
    return(x)  
}

###################################################################
#get data ready for sparta

#takes a set of records and returns a dataframe suitable for analysis
#columns include the list length and presence/absence of the focal specie
cast_recs <- function(records, resolution='visit', focalspname='focal'){
  
  castrecs <- dcast(records, Year + Site + Visit ~ ., value.var='Species', fun=LenUniq)
  spdata <- subset(records, Species==focalspname) #simply the subset of data for the focal species
  
  #specify list length column
  names(castrecs)[ncol(castrecs)] <- 'L'
  # merge the two
  castrecs <- merge(castrecs, spdata, all=T, nomatch=FALSE)
  
  #specific focal species name
  names(castrecs)[ncol(castrecs)] <- focalspname #changed from 'focal'
  #castrecs[ncol(castrecs)] <- as.logical(!is.na(castrecs[ncol(castrecs)]))
  return(castrecs)
}

#################################################################################################

#run analysis

#takes a simulated dataset and runs each method

run_all_methods <- function(records, min_sq=5, summarize=T, nyr=3){
  
  ######## DATA FRAME FOR visit-based analysis
  simdata <- cast_recs(records, resolution='visit') # 0.02 seconds
  
  # for later: which are on well-sampled sites (3 years data)
  i <- is.gridcell.wellsampled2(simdata, n=nyr)
  
  ######## WHICH SITES HAS THE FOCAL SPECIES EVER BEEN RECORDED ON? 
  focalsites <- unique(subset(records, Species=='focal')$Site)
  
  ## OCCUPANCY
  # Added February 2014 by NJBI, based on code originally written by Arco & Marnix
    require(R2jags)
    
    ######################################## Setup BUGS data
    
    ni<-5000; nb<-2500; nt<-3; nc<-3 # as Marnix
    
    # need to get a measure of whether the species was on that site in that year, unequivocally, in zst
    #it should have dims=c(nsite, nyear)
    zst <- acast(simdata, Site~factor(Year), value.var='focal', max, fill=0) # initial values for the latent state = observed state
    nyear <- LenUniq(simdata$Year) 
    
    # what are we going to monitor
    parameters <- c("fit", "fit.new", "psi.fs", "regres.psi","regres.pdet", "sigma2","sd.lp", "mu.lp", "tau.lp", "pdet.alpha")
    
    ##################################### function
    
    initiate <- function(z, i=1) {
      init <- list (z=z,  alpha.p=rep(runif(1, -2, 2), nyear))
      if(i>=2) init$LL.p=runif(1, -2, 2)
      if(i==3) {
        init$dtype2.p=runif(1, -2, 2)
        init$dtype3.p=runif(1, -2, 2)
      }
      init
    }
    
    ##################################### run the occupancy models
    
    OccResults <- sapply(OccMods, function(OccMod){ 
      # work out which Occmod we're using and make the necessary arrangments
      # the name of the OccMod defines how it should be set up
      #print(OccMod)
      init=1
      
      # it also defines the name of the file ('SS' criterion is not used to determine which file is used)
      OccModFile <- gsub('SS\\+', '', OccMod)
      
      if(OccMod=='Full') OccMod <- 'SS+LL+Site'
      
      # first figure out if we're doing the site selection
      if(grepl('SS', OccMod)) { # Site Selection Criterion: restrict the data to sites represented 3 times
        # identify the visits that are on sites wih three years data
        # first determine the number of years per site
        yps <- rowSums(acast(simdata, Site~Year, length, value.var='L')>0)
        sites_to_include <- as.numeric(names(yps[yps>=nyr]))
        zst <- zst[dimnames(zst)[[1]] %in% sites_to_include,]
        i <- simdata$Site %in% sites_to_include
        #i <-is.gridcell.wellsampled2(simdata) # same as three steps but doesn't help with zst
      } else i <- TRUE # use all the rows
      
      # now assemble the bugs_data and related objects
      #need to convert Site identities into row numbers
      site_to_row_lookup <- data.frame(Site=as.integer(dimnames(zst)[[1]]),rownum=1:nrow(zst)) 
      
      bugs_data <- with(merge(simdata[i,], site_to_row_lookup), # adds rownum to simdata (used below)
                        list(y=as.numeric(focal), Year=Year, Site=rownum, 
                             nyear=nyear, nsite=nrow(zst), nvisit=nrow(simdata[i,]),
                             sumX=sum(unique(Year)), sumX2=sum(unique(Year)^2)))
      
      if(grepl('LL', OccMod)) { # List length as a covariate
        bugs_data$logL=log(simdata[i,]$L)
        bugs_data$dtype2p_min = -10; bugs_data$dtype2p_max=10 #constraints on the priors
        parameters <- c(parameters, 'LL.p')
        init=2 # for defining which initial values are required
      }  
      
      if(!grepl('Site', OccMod)) parameters <- setdiff(parameters, 'sigma2') # this variance term is only used in Site models
      
      if(grepl('Arco', OccMod)) { # Arco's model
        bugs_data$DATATYPE2 = as.numeric(simdata$L %in% 2:3) # a short list
        bugs_data$DATATYPE3 = as.numeric(simdata$L > 3) # 'full' list
        bugs_data$dtype2p_min = -10; bugs_data$dtype2p_max=10 #constraints on the priors
        bugs_data$dtype3p_min= -10; bugs_data$dtype3p_max=10 #constraints on the priors
        parameters <- c(parameters, "pdet.d2","dtype2.p", "pdet.d3", "dtype3.p")
        init=3
      }
      
      # set the initial values
      init.vals <- replicate(nc, initiate(z=zst, i=init), simplify=F)
      
      model_file <- paste0('Occupancy/Occ_',gsub('\\+','_',OccModFile),'.bugs')
      
      out <- jags(bugs_data, init.vals, parameters, model.file=model_file, 
                  n.chains=nc, n.iter=ni, n.thin=nt, n.burnin=nb, DIC=TRUE)  
      # try paralellising
      #out <- jags.parallel(bugs_data, init.vals, parameters, model.file=model_file, 
      #           n.chains=nc, n.iter=ni, n.thin=nt, n.burnin=nb, DIC=TRUE)      
      
      out$BUGSoutput$summary
    }, USE.NAMES=T, simplify=F)
    
    ### Now get the results from each models into a format that matches the rest of the output  
    names(OccResults) <- OccMods
    
    Occ_trends <- as.data.frame(t(sapply(
      OccResults, function(x) x['regres.psi',c('mean','2.5%','97.5%','Rhat')])))
    # convert to a effective p-value: just a 1 or 0 
    names(Occ_trends)[1] <- 'trend'
    Occ_trends$p <- as.numeric(0>apply(Occ_trends, 1, function(x) x['2.5%']*x['97.5%']))
    Occ_trends$name <- rownames(Occ_trends)
    Occ_trends <- melt(Occ_trends[,c(6,1,5,4)], id='name')
    
    Occ_out <- Occ_trends$value
    names(Occ_out) <- with(Occ_trends, paste0('Occ+',name,'_', variable))
    
    output <- c(output, Occ_out)
  } 
  
  
iterate_all_scenarios <- function(nreps=1, nSites=1000, nSpecies=50, nYrs=10, pSVS=0.05, save_data=F, pFocal=list(Occ=0.5, DetP=0.5), vrs=F, mv=20, stoch=T,
                                  p_short=list(init=0.6,final=0.9), pDetMod=0.2, decline=0, id='', combos=F, Scenarios='BCDF', 
                                  inclMM=F, Frescalo=F, frescalo_path=NULL, Occ=Occ, nyr=nyr, writePath = getwd()) {
  # this function is the wrapper for the standard procedure of generating data then analysing it and spitting the output
  # TO DO: allow save data to be an integer defining the number of reps to be printed. e.g. the first 100 out of 1000
  # As a workaround, I've added the 'inclMM' argument: if FALSE it bypasses the mixed model, which takes most time.
  # 8 April: I separated the data generation from data analsysis
  # Feb-March 2014: I added the arguments Occ and nyr
  
  x <- system.time(
    output <- replicate(nreps, { # probeme when nreps>1. Hang on - is it when Frescalo=F?
      # first generate the records
      records <- generate_all_scenarios(nSites=nSites, nSpecies=nSpecies, nYrs=nYrs, pSVS=pSVS, save_data=save_data, 
                                        pFocal=pFocal, p_short=p_short, pDetMod=pDetMod, decline=decline, id=id, 
                                        combos=combos, Scenarios=Scenarios, mv=mv, vrs=vrs, stoch=stoch)
      
      # now analyse the data
      sapply(records, run_all_methods, nyr=nyr)
    })
  )
  attr(output,"simpars") <- list(nreps=nreps,nSpecies=nSpecies,nSites=nSites,nYrs=nYrs,pSVS=pSVS,pFocal=pFocal,p_short=p_short,
                                 pDetMod=pDetMod,decline=decline, visit_rich_sites=vrs, stochastic=stoch, max_vis=mv, nyr_SS=nyr)
  attr(output,"combos") <- list(Scenarios=Scenarios, combos=combos, MM=inclMM, Frescalo=Frescalo)
  attr(output, "id") <- id
  attr(output, "elapsed_time") <- as.numeric(x[3])
  dir.create(path = writePath, showWarnings = FALSE)
  save(output, file=paste(writePath, '/SimOutput_',id,'_',dim(output)[3],'.rData', sep=''))
  return(output)
  gc()
}

#################################################################################################
#model statistics 

get_all_stats <- function(output, save_to_txt=T, sf=3, writePath = getwd()){
    # 1/5/13: minor changes so that parameters are read from attr(output, ...) rather than passed
    
    if(dim(output)[3] == 1) {
        # 17/1/13: a quick hack to make the function work with only one replicate
        require(abind)
       
        # Added 9/5/3: doing this removes the attr
        simpars <- attr(output, "simpars")
        combos <- attr(output, "combos")
        id <- attr(output, 'id')
        time <- attr(output, "elapsed_time")
        
        output <- abind(output[,,1],output[,,1], along=3)

        # now add back the simpars
        simpars -> attr(output, "simpars")
        combos -> attr(output, "combos")
        id -> attr(output, 'id')
        time -> attr(output, "elapsed_time")

    }
    
    error_rates <- get_error_rates(output, save=F)
    summ_stats <- get_summary_stats(output, save=F, sf=sf)

    # how many replicates are valid - for Mixed model it's sometimes less than the specified
    p_val_cols <- grep('_p$',dimnames(output)[[1]]) #changed 16 Oct so only matches to end of string
    n_valid_reps <- apply(output[p_val_cols,,],1:2,function(a) sum(!is.na(a)))
    dimnames(n_valid_reps)[[1]] <- gsub(x=dimnames(n_valid_reps)[[1]], pattern='_p', repl='_nReps')
    
    x <- t(cbind(error_rates, summ_stats, t(n_valid_reps)))
    if(save_to_txt)	{
        id <- attr(output, "id")
        write.csv(x, file=paste(writePath, '/SimStats_',id,'_',dim(output)[3],'.csv', sep=''))
        return(x)
	} else {return(x)}
}

error_rate <- function(p, alpha=0.05) {p <- p[!is.na(p)]; length(p[p<=alpha])/length(p)}

test_power <- function(x, alpha=0.05, positive) {
    #modified from error_rate
    #now, the power is the proportion of replicates that are *both* less than alpha AND in the correct direction
    right_direction <- (x[1,] > 0) == positive #logical vector 
    p <- x[2,]
    if(any(p <= alpha & !right_direction, na.rm=T)) print('significant correlation opposite to true!')
    return(length(p[p<=alpha & right_direction])/length(p))
}


get_error_rates <- function(output, datecode=NULL, save_to_txt=T, sf=4, true_change=NULL){
	# first get the p-values from the methods that actually return p-values
	# 24 October: replaced dnorm with  one_to_two_tail(pnorm())): the former is conservative
	# 5-6 November: modified so that testing for power only looks for negative (or positive) associations (true_change)
	# 4/2/13 amended for cases where p includes NAs (typically MM under scenario C)
    # 1/5/13: minor changes so that parameters are read from attr(output, ...) rather than passed
    
    # is it power or validity? If not passed then read from output directly
    # fixed an error: 9 May so that power calculated in correct direction
    if(is.null(true_change)) true_change <- - attr(output, 'simpars')$decline

    #which columns contain the p-values
	p_val_cols <- grep('_p$',dimnames(output)[[1]]) #changed 16 Oct so only matches to end of string
    
	if(true_change==0) { 
		error_rates <- sapply(p_val_cols, function(i) apply(output[i,,], 1, error_rate)) #test validity
		#plr = apply(one_to_two_tail(pnorm(output[dimnames(output)[[1]] == 'plr',,])),1,error_rate)
		#Telfer = apply(one_to_two_tail(pnorm(output[dimnames(output)[[1]] == 'Telfer',,])),1,error_rate)
	} else { 
	  # added 16/9/13: add the word 'trend' onto Telfer & plr residual (index)
	  # this is the simplest way of getting around the problem of matching
	  # it's actually only necessary for the test of power
	  dimnames(output)[[1]] <- gsub(dimnames(output)[[1]], pattern='Telfer$', repl='Telfer_trend')
	  dimnames(output)[[1]] <- gsub(dimnames(output)[[1]], pattern='plr$', repl='plr_trend')
	  
	  # if testing power, we need to know which columns match the p-value columns
	  trend_names <- gsub('p$','trend',dimnames(output)[[1]][p_val_cols])
	  trend_cols <- sapply(trend_names, grep, dimnames(output)[[1]], fixed=T)
	  #trend_cols <- which(dimnames(output)[[1]] %in% trend_names) 
    
    
    error_rates <- sapply(1:length(p_val_cols), function(i) 
    apply(output[c(trend_cols[[i]], p_val_cols[[i]]),,], 2, test_power, positive=true_change>0)) #power (fixed error 21 Nov)
    #plr = apply(one_to_two_tail(pnorm(output[dimnames(output)[[1]] == 'plr',,])),1,error_rate) #TO FIX - doesn't account for wrong direction
		#Telfer = apply(one_to_two_tail(pnorm(output[dimnames(output)[[1]] == 'Telfer',,])),1,error_rate) #TO FIX - doesn't account for wrong direction
	}
	
	varnames <- dimnames(output)[[1]][p_val_cols]
	dimnames(error_rates)[[2]] <- substr(varnames, 1, regexpr('_',varnames) - 1)

	# now append the p-values from the standardised residuals
	#error_rates <- cbind(prop.diff = NA, plr = plr, Telfer = Telfer,	error_rates)
    
    # for some combos (especially mixed model under scenario C) there are some reps which don't return enough data
    error_rates <- round(error_rates,sf)
    
    if (save_to_txt) write.csv(error_rates, file=paste('ErrorRates_',datecode,'_',dim(output)[3],'.csv', sep=''))
	return(error_rates)
	
	}


get_summary_stats <- function(output, datecode=NULL, sf=3, save_to_txt=T){
    # the various 'rows' of output contain a range of information types. Separate them out
    i <- grep('_trend', dimnames(output)[[1]]) # added 25/1/13
    i <- c(grep('Recs_', dimnames(output)[[1]]), i) # added 14/12/12, modified 22/1/13
    i <- c(grep('_t[0-9]', dimnames(output)[[1]]), i)
    i <- c(grep('pCombosUsed', dimnames(output)[[1]]), i) # if no mixed model this appends -1 (i.e. it gets ignored). Slight modification for multiple MMs (3/11/12)
    i <- c(grep('Fr_', dimnames(output)[[1]]), i) # if no Frescalo this appends -1 (i.e. it gets ignored). Added 17/1/13, modified 24/1

    # mean value for all stats (na.rm added 4/2/13)
    # 1/5/13: changed to median since Maes' method occasionally returns Inf (and is bounded at zero)
    x <- apply(output, 1:2, median, na.rm=T)[i,] 
    
    #strsplit(dimnames(x)[[2]], '_') # add this in future
    #x <- t(signif(x,sf)) # transpose and remove extraneous decimal places
    x <- t(round(x,sf)) # changed from above to avoid rounding the number of records to nearest 100!
    if (save_to_txt) write.csv(x, file=paste('SummaryStats_',datecode,'_',dim(output)[3],'.csv', sep=''))
    return(x)
}





plot_error_rates <- function(output, error_rates, datecode){
	# the various 'rows' of output contain a range of information types. Separate them out
	p_val_cols <- grep('_p',dimnames(output)[[1]])
	recording_rate_cols <- grep('_t[1-9]',dimnames(output)[[1]])
	method_cols <- setdiff(1:dim(output)[1], c(p_val_cols, recording_rate_cols))
	
	# plot a histogram of the other parameters
	pdf(file=paste('Sim_T1Errors_',datecode,'_',dim(output)[3],'.pdf', sep=''), onefile=T, paper='a4', height=11.69, width=8.27)
	par(mfrow=c(dim(output)[2],length(method_cols)), mar=c(5,2,3,1), omi=c(0,0,0,0))

	for(j in 1:dim(output)[2]) # for each recording scenario
		for(i in 1:length(method_cols)) {# for each test statistic, excluding the p-values
			hist(output[method_cols[i],j,], xlab=dimnames(output)[[1]][method_cols[i]], col.lab='blue', main=NULL)
			if(i==1) {title(main=paste(dimnames(output)[[2]][j], sep=''), col.main='red')
			} else {title(sub=paste(quote(alpha),'=',error_rates[j,i], sep=''),col.sub='blue')}
			#} else {title(sub=paste(expression(alpha),'=',error_rates[j,i], sep=''),col.sub='blue')}
			#} else {title(sub=paste(substitute(alpha),'=',error_rates[j,i], sep=''),col.sub='blue')}
			#} else {title(sub=substitute(paste(alpha,'=',error_rates[j,i], sep='')),col.sub='blue')}
			#} else {title(sub=paste(quote(substitute(alpha)),'=',error_rates[j,i], sep=''),col.sub='blue')}
			#} else {title(sub=expression(paste(alpha,'=',eval(error_rates[j,i]))))}
			}	
	dev.off()	
	}


plot_error_rates_trace <- function(output, datecode=NULL, ignore.first=200){
	#plots how the error rates change with increasing replicate number
	#require(lattice)
	require(ggplot2)
    nreps <- dim(output)[3]
	if(nreps < ignore.first) sample_reps <- 2:nreps else sample_reps <- c(1:4*50, 250:nreps)
	er <- sapply(sample_reps, function(x) get_error_rates(output[,,1:x], save_to_txt=F, tr=attr(output, 'simpars')$decline), simplify=F)
	er <- melt(er)
	er$repnum <- sample_reps[er$L1]
	#pdf(file=paste('Sim_TraceErrors_',datecode,'_',dim(output)[3],'.pdf', sep=''), onefile=T, paper='a4r', width=11.69, height=8.27)
	#xyplot(data=er, value ~ repnum|Var1, gr=Var2, type='l', xlab='number of replicates', ylab='error rate', auto.key=T, scales=list(relation='free'), as.table=T)	
    names(er)[2] <- 'Method'
    qp <- qplot(data=er, x=repnum, y=value, col=Method, group=Method, geom='line') 
    qp + facet_wrap(~ Var1, nr=2) + xlab('number of replicates') + ylab('error rate')
    #dev.off() #pdf doesn't work!
	}


plot_summary_stats <- function(output, datecode){
	# the various 'rows' of output contain a range of information types. Separate them out
	# NB This will look congested if multiple mixed model thresholds were used
	t1_cols <- grep('_t1',dimnames(output)[[1]])
	t2_cols <- grep('_t2',dimnames(output)[[1]])
	#nc <- dim(output)[1]
	sc <- grep('MM_pCombosUsed', dimnames(output)[[1]]) # 'starting column' is given by this, the first summary statistic

	# plot a histogram of the other parameters
	pdf(file=paste('Sim_Summary_',datecode,'_',dim(output)[3],'.pdf', sep=''), onefile=T, paper='a4', height=11.69, width=8.27)
	par(mfrow=c(dim(output)[2],1+length(t1_cols)), mar=c(5,2,3,1), omi=c(0,0,0,0))

	for(j in 1:dim(output)[2]) # for each recording scenario
		for(i in c(sc,t1_cols)) {# for each summary stat
			hist(output[i,j,], xlab=dimnames(output)[[1]][i], col.lab='blue', main=NULL)
			if(i==sc) {title(main=paste(dimnames(output)[[2]][j], sep=''), col.main='red')}
			title(sub=paste('Mean=',round(mean(output[i,j,]),3), sep=''),col.sub='blue')
				}

	for(j in 1:dim(output)[2]) # for each recording scenario
		for(i in c(sc,t2_cols)) {# for each summary stat
			hist(output[i,j,], xlab=dimnames(output)[[1]][i], col.lab='blue', main=NULL)
			if(i==sc) {title(main=paste(dimnames(output)[[2]][j], sep=''), col.main='red')}
			title(sub=paste('Mean=',round(mean(output[i,j,]),3), sep=''),col.sub='blue')
				}
				
	dev.off()	
	}
	

plot_summary_stats3 <- function(output, datecode=NULL, maxN=7){
	# New version of above using boxplot over hist AND transposed
	# the various 'rows' of output contain a range of information types. Separate them out
	t1_cols <- grep('_t1',dimnames(output)[[1]])
	#t2_cols <- grep('_t2',dimnames(output)[[1]]) #should be just t1_cols + 1
	#nc <- dim(output)[1]
	#sc <- grep('MM_pCombosUsed', dimnames(output)[[1]]) # 'starting column' is given by this, the first summary statistic
	stat_names <- gsub('_t1', '', dimnames(output)[[1]][t1_cols])
	
	# plot a histogram of the other parameters
	pdf(file=paste('Sim_Summary_',datecode,'_',dim(output)[3],'.pdf', sep=''), onefile=T, paper='a4r', width=11.69, height=8.27)
	par(mfrow=c(length(t1_cols),7), mar=c(4,2,2,1), omi=c(0,0,0,0)) # 7 is the number of basic scenarios - any others get put on a second page
	
	for(i in 1:length(t1_cols)) # for each summary stat
		for(j in 1:maxN) {# for each recording scenario
			#temp <- output[t1_cols[c(i,i+1)],j,]
			temp <- output[c(t1_cols[i],t1_cols[i]+1),j,]
			dimnames(temp)[[1]] <- c('t1', 't2')
			boxplot(t(temp), xlab=stat_names[i], col.lab='blue', main=NULL)
			if(i==1) {title(main=paste(dimnames(output)[[2]][j], sep=''), col.main='red')}
			#title(sub=paste('Mean=',round(mean(output[i,j,]),3), sep=''),col.sub='blue')
			}

	dev.off()	
	}
	

recording_cycle <- function(pSVS=0.05, true_data, max_vis=10, VisRichSites=F, stochastic=T) {
    # runs a 'recording cycle': nVisits are apportioned randomly among the sites (rows) in true_data: some sites get multiple visits
    # 3 December: modified to give 'fatter tails' in the distribution of recording effort among sites
    #   in UK recording data, about 1/4 of monads visited each year get further visits
    #   For the Dutch Dragonfly & Butterfly data, the figure is about 1/2
    #   The parameterization here is for UK.
    #   this makes the total number of visits and expectation, rather than fixed
    #  8/4/13: I removed the correlation between p(visited) and species richness
    # 24/4/13: New formulation based on power law. NB this means number of visits varies from year to year
    #  2/5/13: I added back the correlatin between p(visited) and species richness, with an option to control
    #   I also added in the option for stochastic (the detault) vs determininistic numbers of visits    
    #  3/5/13: VisRichSites now additionally determines the number of visits received by each site (if selected)
    
    fx <- function(a=-3,b=-2, nSite=1000, maxV=10, stochastic=T){
        # This function defines the distribution of visits among sites in each year, based on the observed power law
        # the power law is truncated at maxV visits per year.
        
        # first define the log probabilities based on the model fit
        pr <- exp(a + b * log(1:maxV))
        
        # now append the probability of getting zero visits
        pr <- c(1-sum(pr), pr)
        
        #enS <- nSite * exp(y) ## the expected number of sites in each group
        # the number of visits at each site is defined by a multinomial distribution
        # this includes the number of sites with zero visits, so remove that from the calculation
        if(stochastic){
            n <- rmultinom(n=1, size=nSite, prob=pr)#[-1] removal of 0 count moved to return statement
        } else {
            n <- round(pr*nSite)
            # are there rounding errors?
            rem <- sum(n) - 1000 # corrected typo 18 june ('-' replaced '<')
            #if there are rounding errors, alter the number of sites in the zero category
            if(rem > 0) n[1] <- n[1] - rem
        }
        return(n[-1])
    }
    
    fxp <- function(pSVS=0.05,prch=0.25, nSite=1000, maxV=10, stochastic=T){
        # a wrapper for fx in which the input parameters are on the measurement, rather than modelled scale:
        #   the proportion of sites receiving 1 visit & prch: the multiplier for doubling the number of visits 
        fx(a=log(pSVS), b=log2(prch), nSite=nSite, maxV=maxV, stochastic=stochastic)
    }
    
    # number of sites
    nS = nrow(true_data)
    
    # 3/5/13 VisRichSites gets used twice: if we only get one then use it twice
    if(length(VisRichSites)==1) {VisRichSites <- rep(VisRichSites, 2)
    } else {VisRichSites <- unlist(VisRichSites)}
    
    # get the number of sites receiving 1, 2, 3 visits
    #sv <- fxp(pSVS=pSVS, prch=0.25, nSite=nS, maxV=max_vis)
    sv <- fxp(pSVS=pSVS, prch=0.25, nSite=nS, maxV=max_vis, stochastic=stochastic) #corrected 18/6/13
    
    # set the probability that sites will be visited
    if(VisRichSites[1]) {prVis <- attr(true_data, "richness")
    } else {prVis <- NULL}

    # to figure out which sites get visited, sample sum(sv) sites without replacement
    # unlike sites_visited, each site appears only once in sites_to_visit 
    sites_to_visit <- sample(1:nS, sum(sv), repl=F, prob=prVis)
    
    # should we order the sites so that speciose sites ALWAYS get most visits?
    if(VisRichSites[2]) {
        # create a temporary dataframe of the selected sites and their richness
        nsp=attr(true_data, "richness")[sites_to_visit]
        sites_to_visit <- sites_to_visit[order(nsp)]
    }
    
    # unpack sv so that it has the same length as sites_to_visit
    nVis <- unlist(sapply(1:length(sv), function(i) rep.int(x=i, times=sv[i])))
    
    #visit_site_Ntimes(i=sites_to_visit[646], times=nVis[646], true_data)
    x <- mapply(FUN=visit_site_Ntimes, i=sites_to_visit, times=nVis, MoreArgs=list(true_data=true_data))
        
    records <- melt(x) #Var2 is the VisitNum - in the new version it goes from 1:max(nVis)
    names(records)[1:2] <- c('Species', 'RepVisit')
    records$Site <- sites_to_visit[records$L1]
    
    # renumber the visits so that they're unique within years, not within site:year combos
    uniq_vis <- dcast(records, Site + RepVisit ~ ., length)
    uniq_vis$id <- 1:nrow(uniq_vis)
    records <- merge(records, uniq_vis)
    records$Visit <- records$id
    
    # return the informative columns, without the occasions where a species was not observed 
    return(subset(records, subset=value==1, select=c(Species, Visit, Site)))
}

recording_visit <- function(spp_vector, p_obs=0.5, S=1){
	# simulate a visit to the site, OR a search for one species across multiple sites
	# takes a vector of species occurrences
	# the simplest way of doing this is to generate the observations for all sites first, even those without actual presences
    # in the default version, all species have equal probability
    # but species-specific detectabilities can be used also
    # detection probabilities can also be modified by the D parameter, which is the intensity of the search
    # for a complete search, S=1. (from Mark Hill)
    
    Hill_search <- function(pr, S){
        #takes a vector of species probabilities and the search intensity, S
        1 - exp(S * log(1-pr))
    }
    
    if (S==1) detected <- rbinom(n=length(spp_vector), size=1, prob=p_obs)
    else detected <- rbinom(n=length(spp_vector), size=1, prob=Hill_search(p_obs,S))
	# the realised set of observations is then the minimim value (i.e. a species was only recorded if both present and detected)
	apply(cbind(detected, spp_vector), 1, min)
}

resample <- function(x, ...) x[sample.int(length(x), ...)] # added 3/11 7 moved to separate function 5/2/13




sims_to_frescalo <- function (records,output_dir,frescalo_path,tp2=FALSE){
  # Tom August - 06/11/12
  # original is in 'Frescalo/Process files/sims_to_frescalo.r'
  # take columns Frescalo needs
  cols<-c("Site","Species","Year")
  fres_in<-records[cols]
  
  # bin years into two time periods
  if(tp2){
    split=mean(unique(fres_in$Year))
    lower<-fres_in$Year<=split # NI added '=' sign to ensure no data is lost
    upper<-fres_in$Year>split
    fres_in[lower,]$Year<-1
    fres_in[upper,]$Year<-2
  }
  fres_in<-unique(fres_in) # added 17/1/13 to remove duplicate entries
  # call the frecalo function
  print(head(fres_in))
  Tfac_StDev<-run_fresc_sims(fres_in,output_dir,frescalo_path)
    
  # return the time factor and standard deviation for the species 'focal'
  return(Tfac_StDev)
}


save_records <- function(records, id='', as.R.obj=T) {
	#saves the output in one of two formats (csv works but has not been fully tested: two empty files in place of true_data)
	#ideally replace timestamp with a replicate number
    #25/4/13: Changed to include 'id', which by default also includes Datestamp
	#names(x)[[1]] <- 'TrueData'
	#names(x) <- gsub('_', '', names(x))
	path=paste('SimRecords', sep='')
	#datecode <- format(Sys.Date(),'%y%m%d')
	timestamp <- format(Sys.time(),'%H%M%S')
	if(as.R.obj) {save(records, file=paste(path,'/SimData_',id,'_',timestamp,'.rData', sep=''))
	} else {for (i in 1:length(x)) write.csv(x[[i]], file=paste(path,'/SimData_',timestamp,'_',names(x)[i],'.csv', sep=''))}
}


shorten_lists <- function(records, p_short=0.25){ #defaults to 25% of lists being short
	# a clever way to simulate short lists is to delete records from 'well-sampled' set by stratified random sampling
	# p_short defines the proportion of lists that should be short
	# If a single number then it's constant across years.
	# if numeric, this remains constant over time. If two numbers, the second number identifies the FINAL value
	increment <- ifelse(length(p_short)==1, 0, diff(unlist(p_short)) / max(records$Year)) # which extra ones should be included in each year
	
	#df of all the visits (Site is redundant but worth retaining for clarity)
	uniq_vis  <- dcast(records, Year + Site + Visit ~.,length, value.var='Species') #0.06 seconds
	# Change NA column name to something sensible
	colnames(uniq_vis)[is.na(colnames(uniq_vis))] <- 'LL'
  uniq_vis$visit_id <- 1:nrow(uniq_vis) # this is necessary to make x easy to understand
	
	prop_short <- p_short[[1]] + increment * uniq_vis$Year
	uniq_vis$target_LL <- targetLL(prop_short)
	uniq_vis$recs_to_remove <- uniq_vis$LL - uniq_vis$target_LL # 'NA' is the produced by dcast(): it's the list length for each visit
	uniq_vis <- subset(uniq_vis, subset=recs_to_remove>0) #restrict uniq_vis to those where pruning is necessary

	records$record_id <- 1:nrow(records)
	records_tmp <- merge(records, uniq_vis, all=F) # records in visits to be 'pruned'

	#~0.1 secs to here: the last bit is quite slow! (0.1-1.4 seconds, depending on nVisits & p_short)
	#recs_to_omit <- unlist(apply(uniq_vis[,c('visit_id','recs_to_remove')], 1, function(x) { #for each visit that has been selected
	#	recs <- subset(records_tmp, visit_id==x[1])$record_id #the identities of all the records in selected visits
	#	sample(recs, size=x[2])
	#	})) #names(recs_to_omit) contains the visit number plus the number within the sample, ie. '23' is the 3rd visit to be sampled from the visit 2 
	
	# this version is much quicker, and *much* less dependent on p_short
	#recs_to_omit <- sapply(1:3, function(i) unlist(with(subset(records_tmp, recs_to_remove==i), tapply(record_id, visit_id, sample, i))))
	#26 October: corrected error in version above!
	
	recs_to_omit <- sapply(1:max(uniq_vis$recs_to_remove), function(i) with(subset(records_tmp, recs_to_remove==i), tapply(record_id, visit_id, resample, i)))
	
	# so the pruned data look like this:
	records <- subset(records, !record_id %in% unlist(recs_to_omit), select=-ncol(records)) # added bug fix 'unlist' 25/10
	#return(records)
	}


subset_recs_by_X <- function(records, X, init=0.5){
	# a clever way to simulate increasing numbers of visits OR Sites over time is to take the well-recorded set and strip out the data based on a set of rules
	# X should be either the vector of sites or visit identities
	# init defines the number or proportion to be surveyed in year zero
    # The subset is made easy because the visits and sites are numbered sequentially
    # sort added 25/1/13 for safety!
    # modified 25/4/13 to account for the fact that nVisits now varies among years

    # first calculate the number of visits in the each year
    nV <- with(records, tapply(Visit, Year, LenUniq))
    #nV <- with(records, tapply(Visit, Year, max)) # should be same as above, but larger by 1 in some years!
    
    #if(init < 1) init <- init * max_vis #max(records$Visit)
    increment <- (1 - init) / max(records$Year) # additional proportion of visits to be included in each year
    pV_include <- init + sort(unique(records$Year)) * increment
    nV_include <- round(nV * pV_include) # vector of length nYear defining the number of records to include
      
    i <- X <= nV_include[records$Year]
	#table(records$Year, i) # looks sensible
	return(records[i,])
}


subset_recs_Biased <- function(records, init=0.5, bias=2, target=NULL){
    # 25 January 2013
    # Modified version of subset_recs_by_X() in which sampling is biased in favour of sites where a target species is present
    # The parameter target is a vector of species presence-absence (either the focal or non-focal)
    # The default setting is for bias=2, indicating that sites with the target species are 2x likely to be visited
    # This parameter is the odds ratio for selecting sites where Target is present compared with where it's absent
    # this is actually over-engineered since the number of visits in the original (unsubsetted) records is fixed across years
    # 8/4/13: added a 'select' argument to the subset statement so that records have same strucutre as other Scenarios
    # modified 25/4/13 to account for the fact that nVisits now varies among years
    
    # first calculate the number of visits in the each year
    nV <- with(records, tapply(Visit, Year, LenUniq))
    #nV <- with(records, tapply(Visit, Year, max)) # should be same as above, but larger by 1 in some years!
    
    #if(init < 1) init <- init * max_vis #max(records$Visit)
    increment <- (1 - init) / max(records$Year) # additional proportion of visits to be included in each year
    pV_include <- init + sort(unique(records$Year)) * increment
    nV_include <- round(nV * pV_include) # vector of length nYear defining the number of records to include

    #df of all the visits
    uniq_vis  <- dcast(records, Year + Site + Visit ~.,length, value.var='Species') #0.06 seconds
    # the NA column is the List Length
    uniq_vis$visit_id <- 1:nrow(uniq_vis) # this is necessary to make x easy to understand
    
    # add the unique visit identity to records
    records <- merge(records, uniq_vis, by=c('Site','Year','Visit'))    
    
    # now create a vector of length = nrow(uniq_vis) indicating whether the focal species is present
    uniq_vis$target <- target[match(uniq_vis$Site, as.numeric(gsub('site','',names(target))))]

    # convert these into probabilities of being sampled, using bias as the odds ratio
    uniq_vis$p_sel <- ifelse(uniq_vis$target, bias, 1)
      
    vis_to_include <- unlist(sapply(unique(records$Year), 
        function(i) { 
            vis_tmp <- subset(uniq_vis,Year==i) # the subset of visits for that year
            # this sometimes fails.
            # this can happen when the number of actual visits is less than expected
            # in year 10 we're sampling the expected number of visits from a vector that should be the same length (e.g. 250)
            # occasionally it's slightly shorter. Possible reasons: one visit had zero species.
            # solution: if statement to bypass
            if(nrow(vis_tmp) <= nV_include[i]) x <- vis_tmp$visit_id
            else {  
                x <- try(sample(vis_tmp$visit_id, size=nV_include[i], replace=F, prob=vis_tmp$p_sel), silent=T)
                if(class(x)=='try-error') {
                    error_report <- list(records=records, uniq_vis=uniq_vis, include=nV_include, i=i)
                    save(error_report, file='try_error.rData')
                }}
            return(x)
        }))
        
    recs_to_return <- subset(records, visit_id %in% vis_to_include, select=c('Species','Visit','Site','Year'))
    # check the output
    #with(uniq_vis, plot(tapply(target, Year, sum), ylim=c(0,max(Visit)), type='l', col='red')) # even across years
    #with(subset(uniq_vis, visit_id %in% vis_to_include), lines(tapply(target, Year, sum), ylim=c(0,max(Visit)))) # increasing over time

    return(recs_to_return)
}


summarize_recording <- function(simdata, nsp){  
  ## Calculate the basic stats, each of the two time periods (split the years evenly)
  # get the number of nonfocal secies overall and in each visit
  
    simdata$nonfocal <- (simdata$L - simdata$focal)/(nsp-1) # proportion of species per visit
    splityr <- mean(range(simdata$Year))
  
  # stats on the visit rate (number of sites visited per year, and multiple times per year)
  Site_visit_stats <- acast(simdata, Site ~ Year, fun=LenUniq, value.var='Visit')	
  summary_stats <- c(
    Recs_tot_visits = nrow(simdata),
    Recs_Sp_Yr = sum(simdata$L)/(nsp * max(simdata$Year)), #added 9/5/13
    Recs_total = sum(simdata$L),
    Recs_focal = sum(simdata$focal),
    VisPerYr_t1 = mean(colSums(Site_visit_stats)[1:splityr]),
        #mean(with(simdata, tapply(Visit, Year, LenUniq))[1:splityr]), # changed now that 'Visit' is not unique
    VisPerYr_t2 = mean(colSums(Site_visit_stats)[-c(1:splityr)]),
        #mean(with(simdata, tapply(Visit, Year, LenUniq))[-c(1:splityr)]),
    focal_t1 = mean(subset(simdata, Year<=splityr)$focal),
    focal_t2 = mean(subset(simdata, Year>splityr)$focal),
    nonfocal_t1 = mean(subset(simdata, Year<=splityr)$nonfocal),
    nonfocal_t2 = mean(subset(simdata, Year>splityr)$nonfocal),
    meanL_t1 = mean(subset(simdata, Year<=splityr)$L),
    meanL_t2 = mean(subset(simdata, Year>splityr)$L),
    p_shortLists_t1 = mean(subset(simdata, Year<=splityr)$L <= 3), #proportion of lists that are 'short' (i.e. less than 4)
    p_shortLists_t2 = mean(subset(simdata, Year>splityr)$L <= 3),
    MeanSitesVisited_t1 = mean(colSums(Site_visit_stats>0)[1:splityr]),
    MeanSitesVisited_t2 = mean(colSums(Site_visit_stats>0)[-c(1:splityr)]),
    #MeanMultiVisitSites_t1 = mean(colSums(Site_visit_stats>1)[1:splityr]),
    #MeanMultiVisitSites_t2 = mean(colSums(Site_visit_stats>1)[-c(1:splityr)])
    PrSitesMultiVisit_t1 = mean((colSums(Site_visit_stats>1)/colSums(Site_visit_stats>0))[1:splityr]),
    PrSitesMultiVisit_t2 = mean((colSums(Site_visit_stats>1)/colSums(Site_visit_stats>0))[-c(1:splityr)])
    )
  return(summary_stats)	
}


targetLL <- function(p_short, ratio=c(4,2,1.5)) {
	# p_short defines the proportion of short lists 
	# balance  defines how that proportion is split between lists of 1, 2 and 3 species long
	# so we draw a number for the number of target species, with NA representing all lists longer than 3
	# this version will return a vector
    # 3 December: I changed the 'balance' argument to reflect better the balance of real recording scheme data
    balance <- ratio/sum(ratio)
	sapply(p_short, function(x) sample(c(1:3,NA), size=1, prob=c(balance*x, 1-x)))
	}
	




#############################################################################
#scenario functions

bias_focal <- function(records, disadvantage=0.5){
  # a clever way to simulate bias *against* is to delete records from 'well-sampled' set by stratified random sampling
  # disadvantage defines the proportion of lists where the focal species should be 'unrecorded'
  # If a single number then it's constant across years.
  # if numeric, this remains constant over time. If two numbers, the second number identifies the FINAL value
  increment <- ifelse(length(disadvantage)==1, 0, diff(disadvantage) / max(records$Year)) # which extra ones should be included in each year
  records$record_id <- 1:nrow(records)
  focal <- subset(records, subset=Species=='focal')
  p_lost <- disadvantage[1] + increment * focal$Year # probability of being 'lost' (un-recorded) is a function of year and disadvantage
  lost <- rbinom(n=nrow(focal), size=1, prob=p_lost) # a vector of zero & 1s indicating  
  record_id_to_lose <- focal$record_id[lost==1]
  return(records[-record_id_to_lose,]) # 
}

#####ARE THE BELOW USED???##############################################################
fit_LadybirdMM <- function(MMdata, nsp=2, nyr=3){ #0.44 seconds
  # this version returns only the coefficients and the proportion of observations that were 'well-sampled'
  # 14 December: minor change: I removed the call to MMdata to outside the function.
  #   this Gives extra flexibility to analyse disaggregated data.
  require(lme4)
  
  #subset the data
  i <- MMdata$L >= nsp
  i[i==T] <- is.gridcell.wellsampled(MMdata$Site[i], n=nyr)
  
  # 4/2/13: with small numbers of visits, it's possible that no gridcells meet the criterion
  # I also centred the data on the mid year in order to improve numerical convergence 
  my <-median(unique(MMdata$Year))
  if(length(unique(MMdata$Site[i])) > 1 & var(MMdata$focal[i]) > 0){ 
    x <- try({# another source of the bug error is if there's not enough to fit the model
      MM <- glmer(focal ~ I(Year-my) + (1|Site), MMdata, subset=i, family=binomial)
      coefs <- as.numeric(coef(summary(MM))[2,]) # should be compatible across versions
    }, silent=T)
    if(class(x)=='try-error'){
      if(grepl('step-halvings failed', x) | grepl('did not converge', x)) coefs <- rep(NA, 4) #the model fails if the data are too sparse
      else save(MMdata, file=paste('MM_ber_tryerror_',nsp,'.rData'))
    }
    # end bug check
  } else coefs <- rep(NA, 4)
  
  return(c(coefs, sum(i)/length(i))) # keep this a two step process in case we later decide to extract other info
}

fit_ladybirdMM_bin <- function(indata, nsp=2, nyr=3, od=F, V=F){
  # indata (simdata) contains 1 row per valid visit, with a true or false for whether it was recorded
  # now we aggregate this to the year:monad level, with a binomial response (not bernoulli) <- thanks to Ben Bolker
  # initially I calculated nVR directly from records, but this includes all the lists of length 1 and the poorly-sampled grid cells
  # optional arguments for modelling Overdispersion (very slow) and verbose output
  
  require(lme4)
  
  #subset the data: remove the short lists (defined by nsp)
  data <- subset(indata, L>=nsp)
  
  # of these visits, which are on well-sampled sites?
  # 21 June: if no thresholds are applied then no need to look for well-sampled set
  if(nsp>1 & nyr>1) data <- subset(data, is.gridcell.wellsampled2(data, n=nyr))
  
  if(length(unique(data$Site)) > 1 & var(data$focal) > 0){
    # we have enough data in the well-sampled set to try running a model
    MMdata <- dcast(data, Year + Site ~ ., fun=length, value.var='L') #how many lists?
    names(MMdata)[ncol(MMdata)] <- 'nVis'
    
    MMdata$nVR <- as.numeric(acast(data, Year + Site ~ ., fun=sum, value.var='focal'))
    
    # to fit a binomial model, we define a new column containing the number of visits without an observaiton of the focal
    MMdata$failures <- with(MMdata, nVis - nVR)
    
    # centre the Year on the median value (for numerical stability)
    MMdata$cYr <- MMdata$Year - median(unique(MMdata$Year))
    
    x <- try({# another source of the bug error is if there's not enough to fit the model
      if(od) {
        MMdata$obs <- 1:nrow(MMdata)
        MM <- glmer(cbind(nVR, failures) ~ cYr + (1|Site) + (1|obs), data=MMdata, family=binomial, verbose=V)
      } else {
        MM <- glmer(cbind(nVR, failures) ~ cYr + (1|Site), data=MMdata, family=binomial, verbose=V)
      }
      
      coefs <- as.numeric(coef(summary(MM))[2,]) # should be compatible with old and new versions of lme4
    }, silent=T)
    if(class(x)=='try-error') {# bug check
      # several sources of error in these models exists.
      # the try statement was originally written to capture datasets that were too small, but these are handled above
      # Jan 2014:  new code to catch errors under lme4 v1
      # some errors we understand
      if(grepl('step-halvings failed', x) | grepl('did not converge', x)) coefs <- rep(NA, 4) #the model fails if the data are too sparse              
      else save(MMdata, file='MM_bin_tryerror.rData')
    }
    
    # calculate the number of rows in the model as a proportion of the total site-year combos
    p_used <- nrow(MMdata)/nrow(unique(indata[,c('Year','Site')]))
    result <- c(coefs, p_used)
  } else result <- c(rep(NA, 4),0) # there's no 'well-sampled' cells
  
  return(result) # keep this a two step process in case we later decide to extract other info
}



fit_Maes <-function(records, splityr=NULL, min_sp=5, var=T, test=4){
  # fits the method described in Maes et al 2012 (Biol Cons 145: 258-266)
  # I checked this by comparing the results against those in Maes et al SI
  # the function returns numbers of sites in 2 time periods (out of the well-sampled ones), the %trend and p-value
  # 29/11/13: updated p-value as per Thierry Onkelinx's helper functions 
  #           (I tried adding the var=T option but it doesn't really help deliver 'sensible' T1 errors)
  # 2/12/13: there have been several attempts to figure out the test statistic here
  #         I've modified the code to allow a choice.
  # 6/12/13: I've realised that low power is due to few sites passing the threshold.
  #         For pSVS=0.05 under Control, only 9% of sites have >=5 species in both tp (12% have >=3 species)
  #         For pSVS=0.1 under Control, 27% of sites have >=5 species in both tp (30% have >=3 species)
  
  
  require(reshape2)
  
  if(is.null(splityr)) splityr <- median(unique(records$Year))
  
  # which time period is each record in?
  records$tp <- 1+ (records$Year > splityr)
  
  # convert the records into a 3D array
  rc <- acast(records, Species ~ Site ~ tp, fun=occurrence, value.var=2)
  
  # what is the observed species richness in each cell in each year
  rc1 <- apply(rc, c(2,3), sum)
  
  # which sites have are well-sampled? (defined as having at least min_sp species in BOTH time periods)
  well_sampled <- as.numeric(dimnames(rc1)[[1]][apply(rc1, 1, function(x) all(x>=min_sp))])
  #well_sampled <- as.numeric(names(which(apply(rc1 >= min_sp, 1, all)))) # alternate formulation
  
  # look at just the data for these well-sampled cells
  rc2 <- rc[,dimnames(rc)[[2]] %in% well_sampled,]
  
  # how many sites for each species in each time period?
  rc3 <- apply(rc2, c(1,3), sum)
  
  # calculate the relative distribution in each time period
  rd <- apply(rc3, 2, function(x) x/sum(x))
  
  n <- colSums(rc3)
  
  ##########################################################
  # 3 helper functions by Thierry Onkelinx
  sampleRd <- function(rd, n, rd.names = factor(seq_len(nrow(rd)))){
    #Generate a new set of relative distributions based on a given set of relative distributions
    #@author Thierry Onkelinx
    #@export
    #@param rd a matrix with relative distributions. The first column contains the relative distribution at the first timepoint. The column column those of the second timepoint. Other columns are ignored.
    #@param n a vector with the number of sampled gridcells in each period. Only the first two are used.
    #@param rd.names an optinal vector with the species names
    #@return a matrix with five columns and as much rows as in rd. 
    # The columns contain: 
    # 1) the resampled relative distribution at timepoint 1
    # 2) the resampled relative distribution at timepoint 2 under the null hypothesis (rd1 == rd2)
    # 3) the resampled relative distribution at timepoint 2 under the alternate hypothesis (rd1 != rd2)
    # 4) the index from Maes et al assuming the null hypothesis and the 
    # 5) observed index from Maes et al based on the new sample.
    t1 <- sample(rd.names, size = n[1], prob = rd[, 1], replace = TRUE)
    t2.0 <- sample(rd.names, size = n[2], prob = rd[, 1], replace = TRUE)
    t2.a <- sample(rd.names, size = n[2], prob = rd[, 2], replace = TRUE)
    t1 <- table(t1) / n[1]
    t2.0 <- table(t2.0) / n[2]
    t2.a <- table(t2.a) / n[2]
    cbind(t1, t2.0, t2.a, 
          d0=(t2.0 - t1) / t1, da=(t2.a - t1) / t1, 
          dx0=(t2.0 - t1)/rd[,1], dxa=(t2.a - t1)/rd[,1]) # Added by NI to reduce the variance
  }
  
  twoSidedPValue <- function(rd, n, distribution, var=T){
    #Calculate two sided p-values for the index from Maes et al based on their bootstrapped distribution under the null hypothesis
    # @author Thierry Onkelinx
    # @export
    # @param rd a matrix with relative distributions. The first column contains the relative distribution at the first timepoint. The column column those of the second timepoint. Other columns are ignored.
    # @param n a vector with the number of sampled gridcells in each period. Only the first two are used. Ignored when distribution is given.
    # @param distribution a list with at least one item H0 contains a matrix with as many rows as rd containing resampled values of the index under the null hypothesis. Will be calculated if missing.
    # @return a vector with two sided p-values for each row of rd
    
    var <- ifelse(var, 4,6) # should we use the randomised value in the denominator or the observed?
    
    if(missing(distribution)){
      if(missing(n)){
        stop("either n or distribution must be defined")
      } else {
        distribution <- list(
          H0 = replicate(1e3, {
            x <- sampleRd(rd = rd, n = n)[, var]
          })
        )
      }
    }
    trend <- (rd[,2]-rd[,1])/rd[,1]
    p <- sapply(seq_len(nrow(rd)), function(i){
      if(is.infinite(trend[i]) | is.na(trend[i])){
        NA
      } else if(trend[i] > 0){
        mean(distribution$H0[i, ] >= trend[i]) * 2
      } else {
        mean(distribution$H0[i, ] <= trend[i]) * 2
      }
    })
    return(cbind(trend, p))  
  }
  
  confintRd <- function(rd, n, distribution, alpha = 0.05, var=T){
    #'Calculate confidence intervals for the index from Maes et al based on their bootstrapped distribution under the alternative hypothesis
    # @author Thierry Onkelinx
    # @export
    #@param rd a matrix with relative distributions. The first column contains the relative distribution at the first timepoint. The column column those of the second timepoint. Other columns are ignored.
    #@param n a vector with the number of sampled gridcells in each period. Only the first two are used. Ignored when distribution is given.
    #@param distribution a list with at least one item Ha contains a matrix with as many rows as rd containing resampled values of the index under the alternative hypothesis. Will be calculated if missing.
    #@param alpha the errorlevel
    #@return a matrix with observed index, lower confidence limits, upper confidence limit and median.
    
    var <- ifelse(var, 5,7) # should we use the randomised t1 in the denominator or the observed?
    
    if(missing(distribution)){
      if(missing(n)){
        stop("either n or distribution must be given.")
      } else {
        distribution <- list(
          Ha = replicate(1e3, {
            x <- sampleRd(rd = rd, n = n)[, var]
          })
        )
      }
    }
    x <- t(apply(
      distribution$Ha, 
      1,
      quantile,
      c(alpha / 2, 1 - alpha / 2, 0.5)
    ))
    #x <- cbind(rd[, 3], x)
    #colnames(x) <- c("observed", "lcl", "ucl", "median")
    colnames(x) <- c("lcl", "ucl", "median")
    x
  } 
  
  ########################################################## end functions by thierry Onkelinx
  
  if(test==1){ # my simple version: binomial probability of t2 observations given prob in T1
    trend <- (rd[,2]-rd[,1])/rd[,1]
    pval <- mapply(FUN=pbinom, q=rc3[,2], prob=rd[,1], MoreArgs=list(size=sum(rc3[,2])))
    #these are one-tailed: convert them to one-tailed
    pval <- one_to_two_tail(pval) 
    Maes_fit <- cbind(trend, pval)
  } else if(test==2) {
    Maes_fit = NULL # to implement
  } else if(test==3) { # thierry#s modification of my bootstrapping suggestion
    Maes_fit <- twoSidedPValue(rd, n=n, var=var)
  } else if(test==4) { # a binomial glm with gridcell sum as denominator
    Maes_fit <- t(sapply(1:nrow(rc3), function(i) {
      obs <- rc3[i,]
      mod <- glm(cbind(obs,n-obs) ~ c(1:2), binomial)
      summary(mod)$coef[2,c(1,4)]
    }))
  } else if(test==5) { # a binomial glm with number of sites as denominator
    Maes_fit <- t(sapply(1:nrow(rc3), function(i) {
      obs <- rc3[i,]
      mod <- glm(cbind(obs,length(well_sampled)-obs) ~ c(1:2), binomial)
      summary(mod)$coef[2,c(1,4)]
    }))
  } else Maes_fit = NULL
  
  Maes <- data.frame(N1=rc3[,1], N2=rc3[,2], trend=Maes_fit[,1], pval=Maes_fit[,2]) 
  attr(Maes, 'GridCellSums') <- n
  attr(Maes, 'wellsampled') <- length(well_sampled)
  return(Maes)
}


fit_Maes_old <-function(records, splityr, min_sp=5){
  # fits the method described in Maes et al 2012 (Biol Cons 145: 258-266)
  # I checked this by comparing the results against those in Maes et al SI
  # I've added a sampling theory to estimate p-values. We'll see whether it's robust!
  # the function returns numbers of sites in 2 time periods (out of the well-sampled ones), the %trend and p-value
  # 31/9/13: updated p-value as per Thierry Onkelinx's code
  
  require(reshape2)
  
  # which time period is each record in?
  records$tp <- 1+ (records$Year > splityr)
  
  # convert the records into a 3D array
  rc <- acast(records, Species ~ Site ~ tp, fun=occurrence, value.var=2)
  
  # what is the observed species richness in each cell in each year
  rc1 <- apply(rc, c(2,3), sum)
  
  # which sites have are well-sampled? (defined as having at least min_sp species in BOTH time periods)
  well_sampled <- as.numeric(dimnames(rc1)[[1]][apply(rc1, 1, function(x) all(x>=min_sp))])
  #well_sampled <- as.numeric(names(which(apply(rc1 >= min_sp, 1, all)))) # alternate formulation
  
  # look at just the data for these well-sampled cells
  rc2 <- rc[,dimnames(rc)[[2]] %in% well_sampled,]
  
  # how many sites for each species in each time period?
  rc3 <- apply(rc2, c(1,3), sum)
  
  # calculate the relative distribution in each time period
  #nS <- colSums(rc1>0)# the number of sites in each time period
  #rd1 <- rc3[,1]/nS[1]
  #rd2 <- rc3[,2]/nS[2]
  # trend <- 100 * (rd2-rd1)/rd1
  
  # 12.9.13: THIS CODE ABOVE IS WRONG! 
  # RE-reading Maes, I see that the denominator is *not* the total number of cells in each period
  # rather, it's the total number of unqiue site-species combos within the well-sampled set (for each period)
  # this is what Maes calles the 'grid cell sum'
  # CORRECTED VERSION HERE:
  rd <- apply(rc3, 2, function(x) x/sum(x))
  #trend <- 100 * (rd[,2]-rd[,1])/rd[,1]    # 13/11/13: trend is estimated below as a proportion, not %
  
  # we can assess the significance of this method as follows
  # first we assume the distribution of each species is equal among poorly-sampled and well-sampled sites
  # Under the null hypothesis that total proportion of sites has not changed,
  # we can calculate the binomial probability of the 'estimated number of successes
  # estimated number of successes is defined here as nsr2 (number of sites recorded in t2)
  # where the number of trials = nS[2]
  # 12.9.13 I've changed this
  
  #nsr2 <- nS[1] * rc3[,2] / length(well_sampled)
  #true_probs <- rc3[,1]/length(well_sampled)
  #pval <- mapply(FUN=pbinom, q=rc3[,2], prob=true_probs, MoreArgs=list(size=nS[1]))
  
  # corrected version
  #pval <- mapply(FUN=pbinom, q=rc3[,2], prob=rd[,1], MoreArgs=list(size=sum(rc3[,2])))
  
  #these are one-tailed: convert them to one-tailed
  #pval <- one_to_two_tail(pval)
  
  # New version, by Thierry Onkelinx
  n <- colSums(rc3)
  #confidence intervals under the alternative hypothesis
  CI <- t(apply(rd, 1, function(x){
    quantile(
      na.omit(#ignore trends where the species is absent in both time periods
        apply(
          #simulate under the alternative hypothesis
          matrix(
            rbinom(2e3, size = n, prob = x) / n,
            nrow = 2),
          2,
          #calculate simulated trend under the alternative hypothesis
          function(y){(y[2] - y[1]) / y[1]}
        )
      ),
      prob = c(0.025, 0.975)
    )
  }))
  
  #p-values under the null hypothesis
  p.values <- t(apply(rd, 1, function(x){
    trend <- (x[2] - x[1]) / x[1]
    trend.null <- na.omit(apply(
      #simulate under the null hypothesis x[1] == x[2]
      matrix(
        rbinom(2e3, size = n, prob = x[1]) / n,
        nrow = 2
      ),
      2,
      #calculate simulated trend under the null hypothesis
      function(y){(y[2] - y[1]) / y[1]}
    ))
    c(
      trend = unname(trend),
      p.negative.trend.one.sided = mean(trend.null <= trend),
      p.positive.trend.one.sided = mean(trend.null >= trend),
      p.absolute.trend.two.sided = mean(abs(trend.null) >= abs(trend))
    )
  }))
  ########## end of Thierry Onkelinx's code    
  
  Maes <- data.frame(N1=rc3[,1], N2=rc3[,2], trend=p.values[,1], pval=p.values[,4]) 
  attr(Maes, 'GridCellSums') <- colSums(rc3)
  attr(Maes, 'wellsampled') <- length(well_sampled)
  return(Maes)
}


#takes a dataframe of observations, with a vector indexing the time period
fit_Telfer <- function(gridcell_counts, min_sq=5) {
  #takes output from Convert_to_2tp and fits the telfer model
  #convert to proportions	
  p1 <- gridcell_counts$n1/attr(gridcell_counts, 'denom')[1]
  p2 <- gridcell_counts$n2/attr(gridcell_counts, 'denom')[2]
  
  #Telfer's method is the *standardized* residual from a logit-logit regression
  model1 <- lm( log(p2/(1-p2)) ~ log(p1/(1-p1)), subset=gridcell_counts$n1 >=min_sq & p2 >0)
  return(rstandard(model1))
}

is.gridcell.wellsampled <- function(CellID, n=3){
  # modified version of filter.gridcells()
  #takes the dataframe and returns the rownumbers of the dataset identifying well-sampled the gridcells
  nyrs <- table(CellID)
  return(CellID %in% names(nyrs)[nyrs >= n])
}

is.gridcell.wellsampled2 <- function(data, n=3){
  #takes the dataframe and returns a logical vector identifying well-sampled gridcells
  #this version copied from the Odonata trend analysis (late Feb 2013)
  #changed 4 March to filter on number of years, not number of visits
  require(reshape2)
  x <- acast(data, Site~Year, fun=length, value.var='L') # x is the number of visits
  num_yrs_visits  <- rowSums(x>0) # convert nVisits to binary and sum across years 
  sites_to_include <- num_yrs_visits >= n  
  return(data$Site %in% dimnames(x)[[1]][sites_to_include])
}

incidental_records <- function(true_data, nYrs, nVisits, p_short, focal=F){
  # generates incidental records for just one species; either the focal or sppSVS
  # each year, generate a set of incidental records, all of the same species
  # first we need a vector of sites in which the target species is found
  # This doesn't work under test of power with nonfocal=T
  
  col <- 1+as.numeric(!focal) # column 1 for the focal, column 2 for sppSVS (the nonfocal)
  sites <- which(true_data[,col]==1) # set of sites where the target species if found
  
  if(length(p_short)==1){
    nInc <- p_short * nVisits # number of incidental records per year
    recs <- replicate(nYrs, sample(as.numeric(sites), nInc, repl=T)) #as.numeric is helpful to avoid confusion
    recs <- melt(recs)
    names(recs) <- c('Visit','Year','Site')
  } else {
    increment <- diff(unlist(p_short)) / nYrs # which extra ones should be included in each year
    nInc <- round((p_short$init + increment * 1:nYrs) * nVisits) # number of incidental records per year
    recs <- lapply(1:nYrs, function(i) sample(sites, nInc[i], repl=T))
    recs <- melt(recs)
    names(recs) <- c('Site','Year')
    recs$Visit <- melt(sapply(nInc, function(x) 1:x))$value
  }
  
  recs$Visit <- recs$Visit + nVisits # these are extra visits, over and above the normal
  recs$Species <- ifelse(focal, 'focal', 'sppSVS')
  return(recs[,c('Species','Visit','Site','Year')]) #structure matches main records, to which this appended
}
