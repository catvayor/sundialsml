/***********************************************************************
 *                                                                     *
 *                   OCaml interface to Sundials                       *
 *                                                                     *
 *             Timothy Bourke, Jun Inoue, and Marc Pouzet              *
 *             (Inria/ENS)     (Inria/ENS)    (UPMC/ENS/Inria)         *
 *                                                                     *
 *  Copyright 2014 Institut National de Recherche en Informatique et   *
 *  en Automatique.  All rights reserved.  This file is distributed    *
 *  under a New BSD License, refer to the file LICENSE.                *
 *                                                                     *
 ***********************************************************************/

#ifndef __NVECTOR_PAR_ML_H__
#define __NVECTOR_PAR_ML_H__

#include <sundials/sundials_nvector.h>
#include <caml/mlvalues.h>

/* OCaml interface to Parallel NVectors.

   See the comments in nvector_ml.h for the interfacing principles common to
   all NVectors.

   Parallel nvectors
   -----------------
   The payload is a triple of Bigarray, int, and MPI communicator.

   The N_Vector content->data field points to the data in the C heap which
   underlies the payload Bigarray. The content->local_length field is set to
   the length of the Bigarray, the content->global_length field is set to
   the value of the int, and the C value corresponding to the MPI
   communicator is duplicated into content->comm.

   The N_Vector ops are identical to those of a standard parallel N_Vector,
   except for nvclone, nvcloneempty, and nvdestroy which are functions,
   implemented in nvector_ml.c, to create the arrangement described here.
*/

// Creation functions
value ml_nvec_wrap_parallel(value payload, value checkfn);

enum nvector_parallel_exn_index {
    NVECTOR_PARALLEL_EXN_IncorrectGlobalSize = 0,
    NVECTOR_PARALLEL_EXN_SET_SIZE
};

#define NVECTOR_PARALLEL_EXN(name)     REGISTERED_EXN(NVECTOR_PARALLEL, name)
#define NVECTOR_PARALLEL_EXN_TAG(name) REGISTERED_EXN_TAG(NVECTOR_PARALLEL, name)

#if SUNDIALS_LIB_VERSION < 500
#define MPI_SUNINDEXTYPE PVEC_INTEGER_MPI_TYPE
#endif

#endif
