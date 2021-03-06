
import  numpy as np
cimport numpy as np

################################################################################
# Includes

cdef extern from "svm.h":
    cdef struct svm_csr_node
    cdef struct svm_csr_model
    cdef struct svm_parameter
    cdef struct svm_csr_problem
    char *svm_csr_check_parameter(svm_csr_problem *, svm_parameter *)
    svm_csr_model *svm_csr_train(svm_csr_problem *, svm_parameter *)
    void svm_csr_free_and_destroy_model(svm_csr_model** model_ptr_ptr)    

cdef extern from "libsvm_sparse_helper.c":
    # this file contains methods for accessing libsvm 'hidden' fields
    svm_csr_problem * csr_set_problem (char *, np.npy_intp *,
         char *, np.npy_intp *, char *, char *, char *, int )
    svm_csr_model *csr_set_model(svm_parameter *param, int nr_class,
                            char *SV_data, np.npy_intp *SV_indices_dims,
                            char *SV_indices, np.npy_intp *SV_intptr_dims,
                            char *SV_intptr,
                            char *sv_coef, char *rho, char *nSV, char *label,
                            char *probA, char *probB)
    svm_parameter *set_parameter (int , int , int , double, double ,
                                  double , double , double , double,
                                  double, int, int, int, char *, char *)
    void copy_sv_coef   (char *, svm_csr_model *)
    void copy_intercept (char *, svm_csr_model *, np.npy_intp *)
    int copy_predict (char *, svm_csr_model *, np.npy_intp *, char *)
    int csr_copy_predict (np.npy_intp *data_size, char *data, np.npy_intp *index_size,
        	char *index, np.npy_intp *intptr_size, char *size,
                svm_csr_model *model, char *dec_values)
    int  copy_predict_proba (char *, svm_csr_model *, np.npy_intp *, char *)
    int  copy_predict_values(char *, svm_csr_model *, np.npy_intp *, char *, int)
    int  csr_copy_SV (char *values, np.npy_intp *n_indices,
        	char *indices, np.npy_intp *n_indptr, char *indptr,
                svm_csr_model *model, int n_features)
    np.npy_intp get_nonzero_SV ( svm_csr_model *)
    void copy_nSV     (char *, svm_csr_model *)
    void copy_label   (char *, svm_csr_model *)
    void copy_probA   (char *, svm_csr_model *, np.npy_intp *)
    void copy_probB   (char *, svm_csr_model *, np.npy_intp *)
    np.npy_intp  get_l  (svm_csr_model *)
    np.npy_intp  get_nr (svm_csr_model *)
    int  free_problem   (svm_csr_problem *)
    int  free_model     (svm_csr_model *)
    int  free_param     (svm_parameter *)
    int free_model_SV(svm_csr_model *model)
    void set_verbosity(int)


def libsvm_sparse_train ( int n_features,
                     np.ndarray[np.float64_t, ndim=1, mode='c'] values,
                     np.ndarray[np.int32_t,   ndim=1, mode='c'] indices,
                     np.ndarray[np.int32_t,   ndim=1, mode='c'] indptr,
                     np.ndarray[np.float64_t, ndim=1, mode='c'] Y, 
                     int svm_type, int kernel_type, int degree, double gamma,
                     double coef0, double eps, double C, 
                     np.ndarray[np.float64_t, ndim=1, mode='c'] SV_data,
                     np.ndarray[np.int32_t,   ndim=1, mode='c'] SV_indices,
                     np.ndarray[np.int32_t,   ndim=1, mode='c'] SV_indptr,            
                     np.ndarray[np.float64_t, ndim=1, mode='c'] sv_coef_data,
                     np.ndarray[np.float64_t, ndim=1, mode='c'] intercept,
                     np.ndarray[np.int32_t,   ndim=1, mode='c'] weight_label,
                     np.ndarray[np.float64_t, ndim=1, mode='c'] weight,
                     np.ndarray[np.float64_t, ndim=1, mode='c'] sample_weight,
                     np.ndarray[np.int32_t,   ndim=1, mode='c'] nclass_SV,
                     double nu, double cache_size, double p, int
                     shrinking, int probability):
    """
    Wrap svm_train from libsvm using a scipy.sparse.csr matrix 

    Work in progress.

    Parameters
    ----------
    n_features : number of features.
        XXX: can we retrieve this from any other parameter ?

    X: array-like, dtype=float, size=[N, D]

    Y: array, dtype=float, size=[N]
        target vector

    ...

    Notes
    -------------------
    See scikits.learn.svm.predict for a complete list of parameters.

    """

    cdef svm_parameter *param
    cdef svm_csr_problem *problem
    cdef svm_csr_model *model
    cdef char *error_msg

    if len(sample_weight) == 0:
        sample_weight = np.ones(values.shape[0], dtype=np.float64)
    else:
        assert sample_weight.shape[0] == indptr.shape[0] - 1, \
               "sample_weight and X have incompatible shapes: " + \
               "sample_weight has %s samples while X has %s" % \
               (sample_weight.shape[0], indptr.shape[0] - 1)

    # set libsvm problem
    problem = csr_set_problem(values.data, indices.shape, indices.data, 
                              indptr.shape, indptr.data, Y.data,
                              sample_weight.data, kernel_type)

    # set parameters
    param = set_parameter(svm_type, kernel_type, degree, gamma, coef0,
                          nu, cache_size, C, eps, p, shrinking,
                          probability, <int> weight.shape[0],
                          weight_label.data, weight.data)

    # check parameters
    if (param == NULL or problem == NULL):
        raise MemoryError("Seems we've run out of of memory")
    error_msg = svm_csr_check_parameter(problem, param);
    if error_msg:
        free_problem(problem)
        free_param(param)
        raise ValueError(error_msg)

    # call svm_train, this does the real work
    model = svm_csr_train(problem, param)

    cdef np.npy_intp SV_len = get_l(model)
    cdef np.npy_intp nr     = get_nr(model)

    # copy model.sv_coef
    # we create a new array instead of resizing, otherwise
    # it would not erase previous information
    sv_coef_data.resize ((nr-1)*SV_len, refcheck=False)
    copy_sv_coef (sv_coef_data.data, model)

    # copy model.rho into the intercept
    # the intercept is just model.rho but with sign changed
    intercept.resize (nr*(nr-1)/2, refcheck=False)
    copy_intercept (intercept.data, model, intercept.shape)

    # copy model.SV
    # we erase any previous information in SV
    # TODO: custom kernel
    cdef np.npy_intp nonzero_SV
    nonzero_SV = get_nonzero_SV (model)

    # SV_data.resize((0,0), refcheck=False) # why is this needed ?
    SV_data.resize (nonzero_SV, refcheck=False)
    SV_indices.resize (nonzero_SV, refcheck=False)
    SV_indptr.resize (<np.npy_intp> SV_len + 1, refcheck=False)
    csr_copy_SV(SV_data.data, SV_indices.shape, SV_indices.data,
                SV_indptr.shape, SV_indptr.data, model, n_features)

    # copy model.nSV
    # TODO: do only in classification
    nclass_SV.resize(nr, refcheck=False)
    copy_nSV(nclass_SV.data, model)

    # # copy label
    cdef np.ndarray[np.int32_t, ndim=1, mode='c'] label
    label = np.empty((nr), dtype=np.int32)
    copy_label(label.data, model)

    # # copy probabilities
    cdef np.ndarray[np.float64_t, ndim=1, mode='c'] probA
    cdef np.ndarray[np.float64_t, ndim=1, mode='c'] probB
    if probability != 0:
        # this is only valid for SVC
        probA = np.empty(nr*(nr-1)/2, dtype=np.float64)
        probB = np.empty(nr*(nr-1)/2, dtype=np.float64)
        copy_probA(probA.data, model, probA.shape)
        copy_probB(probB.data, model, probB.shape)

    svm_csr_free_and_destroy_model (&model)
    free_problem(problem)
    free_param(param)

    return label, probA, probB



def libsvm_sparse_predict (np.ndarray[np.float64_t, ndim=1, mode='c'] T_data,
                            np.ndarray[np.int32_t,   ndim=1, mode='c'] T_indices,
                            np.ndarray[np.int32_t,   ndim=1, mode='c'] T_indptr,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] SV_data,
                            np.ndarray[np.int32_t,   ndim=1, mode='c'] SV_indices,
                            np.ndarray[np.int32_t,   ndim=1, mode='c'] SV_indptr,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] sv_coef,
                            np.ndarray[np.float64_t, ndim=1, mode='c']
                            intercept, int svm_type, int kernel_type, int
                            degree, double gamma, double coef0, double
                            eps, double C, 
                            np.ndarray[np.int32_t, ndim=1] weight_label,
                            np.ndarray[np.float64_t, ndim=1] weight,
                            double nu, double cache_size, double p, int
                            shrinking, int probability,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] nSV,
                            np.ndarray[np.int32_t, ndim=1, mode='c'] label,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probA,
                            np.ndarray[np.float64_t, ndim=1, mode='c'] probB):
    """
    Predict values T given a model.

    For speed, all real work is done at the C level in function
    copy_predict (libsvm_helper.c).

    We have to reconstruct model and parameters to make sure we stay
    in sync with the python object.

    Parameters
    ----------
    X: array-like, dtype=float
    Y: array
        target vector

    Optional Parameters
    -------------------
    See scikits.learn.svm.predict for a complete list of parameters.

    Return
    ------
    dec_values : array
        predicted values.
    """
    cdef np.ndarray[np.float64_t, ndim=1, mode='c'] dec_values
    cdef svm_parameter *param
    cdef svm_csr_model *model
    param = set_parameter(svm_type, kernel_type, degree, gamma,
                          coef0, nu, cache_size, C, eps, p, shrinking,
                          probability, <int> weight.shape[0], weight_label.data,
                          weight.data)

    model = csr_set_model(param, <int> nSV.shape[0], SV_data.data,
                          SV_indices.shape, SV_indices.data,
                          SV_indptr.shape, SV_indptr.data,
                          sv_coef.data, intercept.data,
                          nSV.data, label.data, probA.data, probB.data)
    #TODO: use check_model
    dec_values = np.empty(T_indptr.shape[0]-1)
    if csr_copy_predict(T_data.shape, T_data.data,
                        T_indices.shape, T_indices.data,
                        T_indptr.shape, T_indptr.data,
                        model, dec_values.data) < 0:
        raise MemoryError("We've run out of of memory")
    # free model and param
    free_model_SV(model)
    free_model(model)
    free_param(param)
    return dec_values



def set_verbosity_wrap(int verbosity):
    """
    Control verbosity of libsvm library
    """
    set_verbosity(verbosity)
