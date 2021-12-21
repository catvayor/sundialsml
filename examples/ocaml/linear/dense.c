#include <stdio.h>
#include <stdlib.h>
#include <sundials/sundials_types.h>
#include <sundials/sundials_direct.h>
#include <sundials/sundials_dense.h>
#include "../../../src/config.h"
#include "../../../src/sundials/sundials_ml.h"

#define NROWS 3
#define NCOLS 3

sunrealtype a_init[NROWS][NCOLS] = {
    {  1.0,  2.0,  3.0},
    {  2.0, -4.0,  6.0},
    {  3.0, -9.0, -3.0}
};

void print_mat(DlsMat m, sundials_ml_index nr, sundials_ml_index nc) {
    int i, j;

    for (i=0; i < nr; ++i) {
	for (j=0; j < nc; ++j) {
	    printf(" % e", DENSE_ELEM(m, i, j));
	}
	printf("\n");
    }
}

void print_vec(sunrealtype* m, sundials_ml_index nr) {
    int i;

    for (i=0; i < nr; ++i) {
	printf(" % e", m[i]);
    }
    printf("\n");
}

void print_pivots(sundials_ml_index* m, sundials_ml_index nr) {
    int i;

    for (i=0; i < nr; ++i) {
	printf(" % lld", (long long)m[i]);
    }
    printf("\n");
}

int main(int argc, char** argv)
{
    DlsMat a = NewDenseMat(NROWS, NCOLS);
    DlsMat b = NewDenseMat(NROWS, NCOLS);
    sundials_ml_index p[NROWS] = { 0.0 };
    sunrealtype s[NROWS] = { 5.0, 18.0, 6.0 };
    int i, j;

    for (i=0; i < NROWS; ++i) {
	for (j=0; j < NCOLS; ++j) {
	    DENSE_ELEM(a, i, j) = a_init[i][j];
	}
    }

    printf("initially: a=\n");
    print_mat(a, NROWS, NCOLS);
    printf("\n");

#if SUNDIALS_LIB_VERSION >= 260
    {
	sunrealtype x[NCOLS] = { 1.0,  2.0, 3.0 };
	sunrealtype y[NROWS] = { 0.0 };
	printf("matvec: y=\n");
	DenseMatvec(a, x, y);
	print_vec(y, NROWS);
	printf("\n");
    }
#endif

    DenseCopy(a, b);

    DenseScale(2.0, b);
    printf("scale copy x2: b=\n");
    print_mat(b, NROWS, NCOLS);
    printf("\n");

    denseAddIdentity(b->cols, NROWS);
    printf("add identity: b=\n");
    print_mat(b, NROWS, NCOLS);
    printf("\n");

    DenseGETRF(a, p);
    printf("getrf: a=\n");
    print_mat(a, NROWS, NCOLS);
    printf("\n       p=\n");
    print_pivots(p, NROWS);
    printf("\n");

    DenseGETRS(a, p, s);
    printf("getrs: s=\n");
    print_vec(s, NROWS);

    DestroyMat(a);
    DestroyMat(b);

    return 0;
}

