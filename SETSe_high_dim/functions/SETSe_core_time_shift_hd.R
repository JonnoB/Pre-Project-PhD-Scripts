#' SETSe Core with time shift for high dimensional feature networks
#' 
#' Internal function. This is a variant of the SETse core algorithm. It runs the SETSe model to find the equilibrium position of the network,
#' it changes the time step if the algo is in the noisy zone. The function is called by auto_setse
#' 
#' @param node_embeddings A data frame The current dynamics and forces experienced by the node a data frame.
#' @param ten_mat A data frame The current dynamics and forces experienced by the node a data frame.
#' @param non_empty_matrix A numeric matrix. contains the index of the non-empty cells in the adjacency matrix. see details.
#' @param kvect A numeric vector of the spring stiffnesses
#' @param dvect A numeric vector of the initial distances between the nodes
#' @param mass A numeric. This is the mass constant of the nodes in normalised networks this is set to 1.
#' @param tstep A numeric value. The time step, measured in seconds, that will be used to calculate the new dynamic state
#' @param max_iter An integer. The maximum number of iterations before stopping. Larger networks usually need more iterations.
#' @param coef_drag A numeric value. Used to set a multiplier on the friction value. This is usualy determined by SETSe_auto
#' @param tol A numeric. The tolerance factor for early stopping.
#' @param sparse Logical. Whether or not the function should be run using sparse matrices. must match the actual matrix, this could prob be automated
#' @param sample Integer. The dynamics will be stored only if the iteration number is a multiple of the sample. 
#'  This can greatly reduce the size of the results file for large numbers of iterations. Must be a multiple of the max_iter
#' @param static_limit Numeric. The maximum value the static force can reach before the algorithm terminates early. This
#' prevents calculation in a diverging system. The value should be set to some multiple greater than one of the force in the system.
#' If left blank the static limit is the system absolute mean force.
#' @param tstep_change a numeric scaler. A value between 0 and one, the fraction the new timestep will be relative to the previous one
#' @param dynamic_reset Logical. Whether the dynamic portion of the emebeddings is reset to zero when the timestep is changed
#' this can stop the momentum of the nodes forcing a divergence, but also can slow down the process. default is TRUE.
#' 
#' @details 
#' This function is usally run inside a more easy to use function such as The SETSe function, SETse_bicomp or SETSe_auto. These
#' wrapper functions make the application of the SETse algorithm more straight foreword. However, this function is included
#' for completeness and to allow ground up experiments
#' 
#' The non_empty matrix contains the row, column position and absolute index and transpose index of the edges in the matrix
#' This means vectors can be used for most operations greatly reducing the amount of memory required and 
#' providing a modest speed increase. The non_empty_matrix is produced by the 'Prepare_data_for_find_network_balance' function.
#' 
#' @return A list of three dataframes
#' \enumerate{
#'   \item The network dynamics describing several key figures of the network during the convergence process, this includes the static_force
#'   \item The node embeddings. Includes all data on the nodes the forces exerted on them position and dynamics at simulation termination
#'   \item A data frame giving the time taken for the simulation as well as the number of nodes and edges. Node and edge data is given
#'   as this may differ from the total number of nodes and edges in the network depending on the method used for convergnence.
#'   For example if SETSe_bicomp is used then some simulations may contain as little as two nodes and 1 edge
#' }
#' 
#' @noRd
# Strips out all pre processing to make it as efficient and simple as possible

SETSe_core_time_shift_hd <- function(node_embeddings, 
                       ten_mat, 
                       non_empty_matrix, 
                       kvect, 
                       dvect, 
                       mass,
                       tstep, 
                       max_iter = 1000, 
                       coef_drag = 1, 
                       tol = 2e-3, 
                       sparse = FALSE,
                       sample = 1,
                       static_limit = NULL,
                       tstep_change = 0.5,
                       dynamic_reset = TRUE){
  #Runs the physics model to find the convergence of the system.
  
  #vectors are used throughout instead of a single matrix as it turns out they are faster due to less indexing and use much less RAM.

  #These have to be matrices if there is a mutli variable option
  NodeList <- node_embeddings[,-1]
  force <- NodeList %>% select(dplyr::starts_with("force_")) %>% as.matrix()
  elevation <- NodeList %>% select(dplyr::starts_with("elevation_")) %>% as.matrix()
  net_tension <-NodeList %>% select(dplyr::starts_with("net_tension_")) %>% as.matrix()
  velocity <- NodeList %>% select(dplyr::starts_with("velocity_")) %>% as.matrix()
  friction <- NodeList %>% select(dplyr::starts_with("friction_")) %>% as.matrix()
  static_force <-NodeList %>% select(dplyr::starts_with("static_force_")) %>% as.matrix()
  net_force <- NodeList %>% select(dplyr::starts_with("net_force_")) %>% as.matrix()
  acceleration <- NodeList %>% select(dplyr::starts_with("acceleration_")) %>% as.matrix()
  
  if(sparse){
    ten_mat <- methods::as(ten_mat, "dgTMatrix") # this is done as Dgt alllows direct insertion of tension without indexing. It 
    #is much faster than the standard format which does require indexing. This is despite dgt being slower to sum the columns
  }
  
  #The default value for the static limit if null is the sum of the absolute force.
  #This value is chosen becuase with good parameterization the static force never exceeds the starting amount.
  if(is.null(static_limit)){
    static_limit <- sum(abs(force))
  }
  
  #gets the dimensions of the matrix for bare bones column sum
  
  non_empty_vect <- non_empty_matrix[,1]
  non_empty_t_vect <- non_empty_matrix[,2]
  non_empty_index_vect <- non_empty_matrix[,3]
  non_empty_t_index_vect <- non_empty_matrix[,4]
  
  #This dataframe is one of the final outputs of the function, it is premade for memory allocation.
  #Although it would be faster to use vectors, the matrix is used only a fraction of the iteration, so has
  #very little impact on speed.
  network_dynamics <- matrix(data = NA, nrow = max_iter/sample, ncol = 6) %>%
    tibble::as_tibble(.name_repair = "minimal") %>%
    purrr::set_names(c("Iter","t", "static_force", "kinetic_force", "potential_energy", "kinetic_energy")) %>%
    as.matrix()
  
  network_dynamics_initial_value <- network_dynamics[1:2, ,drop = FALSE]
  network_dynamics_initial_value[1,] <- c(0, 0, sum(abs(force)), 0,0,0)
  network_dynamics_initial_value <- network_dynamics_initial_value[1 , ,drop = FALSE]
  
  one_vect <- rep(1, nrow(NodeList))
  
  Iter <- 1
  current_time <- 0
  is_noisy <- FALSE 
  system_stable <- FALSE
  
  #get the time the algo starts
  start_time <- Sys.time()
  
  #run the while look as long as the iterations are less than the limit and the system is not stable
  while((Iter <= max_iter) & !system_stable ){
    
    #calculate the system dynamics. Either sparse or dense mode
    #sparse or dense mode chosen by user on basis of network size and of course sparsity
    
    #The code is not put in sub-functions as this creates memory management problems and half the time
    #the program runs can be spent auto calling gc(). This reduces the copying of data...I think
    #It overwirtes the preious values but doesn't create anything else
    #NodeList2 <- NodeList
    
    #####
    #create the tension matrix
    #####
    #dz is the change in eleveation
    #Using drop = FALSE here prevents single feature/column matrices from being conveted to vectors
    #Although vectors are faster this causes an error to be thrown when using rowSums when calculating Hvect
    #and so cannot be used. 
    dzvect <- elevation[non_empty_t_vect,, drop = FALSE] - elevation[non_empty_vect,, drop = FALSE] #The difference in height between adjacent nodes 
    
    #the hypotenuse of the spring distance triangle
    Hvect <- sqrt(rowSums(dzvect^2) + dvect^2)
    
    #The remaining dynamics are calculated here
    
    elevation[,] <- velocity*tstep +0.5*acceleration*tstep*tstep + elevation #Distance/elevation s1 = ut+0.5at^2+s0
    velocity[,] <- velocity + acceleration*tstep #velocity v1 = v0 +at
    static_force[,] <- force + net_tension #static force 
    
    if(sparse){
      #This uses the matrix column aggregation functions which can be used on sparse matrices. This is faster and much more memory
      #efficient for large matrices. It is also faster to tranpose and use column sum... I don't know why
      for(y in 1:ncol(dzvect)){
        ten_mat@x <-{kvect*(Hvect-dvect)*dzvect[,y]/Hvect}
        net_tension[,y] <- Matrix::colSums(Matrix::t(ten_mat)) #colsum is faster than row sum even accounting for the transpose
        
      }
    }else{
      #This uses the standard dense matrices, this is faster for smaller matrices.
      #the tension vector. the dZvect/Hvect is the vertical component of the tension
      for(y in 1:ncol(dzvect)){
        ten_mat[non_empty_index_vect] <- kvect*(Hvect-dvect)*dzvect[,y]/Hvect
        net_tension[,y] <- ten_mat %*% one_vect  #.rowSums(ten_mat, m = m[1], n = m[1]) #tension
        
      }
    }
    friction[,] <- coef_drag*velocity #friction of an object in a viscous fluid under laminar flow
    net_force[,] <- static_force - friction #net force
    acceleration[,] <- net_force/mass #acceleration
    
    if((Iter %% sample)==0){
      #The row of the networks dynamics dataframe/matrix the current data will be inserted into  
      dynamics_row <- Iter/sample 
      ##
      ##This can be removed it is only for debugging
      ##
      # print(paste("Dyanmics row", Iter, 
      #             "is noisy?", 
      #             sum(abs(static_force)) > network_dynamics[dynamics_row-1,3],
      #             "current",  round(sum(abs(static_force))) ,
      #             "previous",round(network_dynamics[dynamics_row-1,3])
      #             ))
  
      #checks to ensure that the reduction in static force is smooth and not in the noisy zone.
      #This is important force most convergence processes as autoconvergence can get stuck in the noisy zone
      #preventing the network from converging. However such a mode is not always desired.
      #The option is implemented in the core algo as noisy convergence can take a long time so
      #automatic termination can greatly reduce the amount of time searching for optimal parameters.
      #The if statment has two conditions
      #1 Is this the second row or higher of the networks_dynamic matrix. Prevents NA values
      #2 The convergence is noisy if the static force at time t is greater than the static force at t-1
      
      if(dynamics_row > 1){
        #The convergence is noisy if the static force at time t is greater than the static force at t-1
        is_noisy <- sum(abs(static_force))  > network_dynamics[dynamics_row-1,3]
        
      }
      #If the convergnece is noisy then load the previous saved versions and change the timestep
      #Otherwise overwrite the previous saved data and continue
      if(is_noisy){
        print("changing timestep")
        #change the tstep
        tstep <- tstep*tstep_change

        #overwrite data with previously saved info
        #If dynamic reset is zero then all the dynamics are set to zero
        force <- force_saved
        elevation <- elevation_saved
        net_tension <- net_tension_saved
        velocity <- velocity_saved*(!dynamic_reset)
        friction <- friction_saved*(!dynamic_reset)
        static_force <- static_force_saved
        net_force <- net_force_saved*(!dynamic_reset) + static_force_saved*(dynamic_reset)
        acceleration <- acceleration_saved*(!dynamic_reset) + (net_force/mass)*(dynamic_reset)
        
      } else {
        
        #as the time can change, it needs to be tracked 
        #current time is not updated if the system reverts to the previous saved point
        current_time <- current_time + sample*tstep
        
        force_saved <- force
        elevation_saved <- elevation
        net_tension_saved <- net_tension
        velocity_saved <- velocity
        friction_saved <- friction
        static_force_saved <- static_force
        net_force_saved <- net_force
        acceleration_saved <- acceleration
        
      }
      #These will be the same as the previous row if the reset has been tripped.
      network_dynamics[dynamics_row,] <- c(Iter, #Iteration
                                           current_time, #time in seconds
                                           sum(abs(static_force)),  #static force. The force exerted on the node
                                           sum(abs(0.5*mass*velocity/tstep)), #kinetic_force #I am not sure how I justify this value
                                           sum( 0.5*kvect*(Hvect-dvect)^2),     #spring potential_energy
                                           sum(0.5*mass*velocity^2)    #kinetic_energy
      ) 
      
      #Checks for early termination conditions. There are three or conditions
      #1 If the static force is not a finite value, this covers NA, NaN and infinite.
      #2 The static force exceeds the static limit
      #4 If the static force is less than the required tolerance then the system is stable and the process can terminate
      system_stable <- !is.finite(network_dynamics[dynamics_row,3])| 
        (network_dynamics[dynamics_row,3] > static_limit) |
        (network_dynamics[dynamics_row,3] < tol)

    }
    
    Iter <- Iter + 1 # add next iter
    
  }
  stop_time <- Sys.time()
  
  time_taken_df <- tibble::tibble(time_diff = stop_time-start_time,
                          nodes = nrow(node_embeddings),
                          edges = length(kvect))
  
  #Early termination causes NA values. These are removed by the below code
  #
  network_dynamics <- as.data.frame(network_dynamics) %>%
    dplyr::filter(stats::complete.cases(.))
  #combine all the vectors together again into a tibble
  Out <- list(network_dynamics = dplyr::bind_rows(as.data.frame(network_dynamics_initial_value), network_dynamics), 
              node_embeddings = dplyr::bind_cols(node_embeddings[,"node",drop=FALSE] , 
                                                 #combine all the values for each dimension into a single tibble
                                                 list(force, elevation, net_tension, 
                                                      velocity, friction, static_force, 
                                                      net_force, acceleration) %>%
                                                   do.call(what = cbind, args = .) %>%
                                                   dplyr::as_tibble() %>%
                                                   dplyr::mutate(t = tstep*(Iter-1),
                                                          Iter = Iter-1)
                                                 
              ),  #1 needs to be subtracted from the total as the final thing
              #in the loop is to add 1 to the iteration
              time_taken = time_taken_df #This is a diff time object!
              )
  
  return(Out)
  
}
