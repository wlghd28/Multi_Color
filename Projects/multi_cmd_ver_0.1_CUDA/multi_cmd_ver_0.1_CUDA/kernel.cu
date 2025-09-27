#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <windows.h>
#include <time.h>
#include <process.h>
#include "FreeImage.h"

#define THUMBNAIL_SIZE 400
// 마스크값 배열
typedef struct MASK
{
	char red;
	char green;
	char blue;
}MASK;
MASK Mask[25];

char** device_name = 0;
int* threadsPerBlock;
int device_num = 0;
int device_count = 0;

double total_Time_CPU = 0;
double total_Time_GPU = 0;
LARGE_INTEGER beginClock, endClock, clockFreq;
LARGE_INTEGER tot_beginClock, tot_endClock, tot_clockFreq;

RGBTRIPLE * pix;
RGBTRIPLE * b_pix;
BITMAPFILEHEADER bfh;
BITMAPINFOHEADER bih;
BITMAPFILEHEADER b_bfh;
BITMAPINFOHEADER b_bih;


// 이미지 정보를 다루기 위해 사용하는 변수
int channel = 5;
int bpl, b_bpl;
int bpl_size, b_bpl_size;
int width, height, b_width, b_height;
int pix_size;
int b_pix_size;	// 5 X 5개 만큼 복붙한 이미지 사이즈
int pad, b_pad;		// 패딩 메모리 사이즈
BYTE trash[3] = { 0 };		// 패딩 메모리

void TiffToBmp();			// tiff파일을 bmp파일로 변환하는 작업
void BmpToTiff();			// bmp파일을 tiff파일로 변환하는 작업
void MaskAlloc();			// 마스크 값 할당
void GraphicInfo();			// 현재 장착된 그래픽카드의 정보를 불러온다
void MultiColor();			// 멀티칼라 연산
char str_Extend[100];				// 생성되는 bmp파일의 이름
void Fwrite_Extend(char * fn);		// 연산된 픽셀값을 bmp파일로 저장한다
cudaError_t extendWithCuda(RGBTRIPLE* b_pix, int size);

__global__ void extendKernel(RGBTRIPLE* d_b_pix, RGBTRIPLE* d_pix, MASK* mask, const int width, const int b_width, const int height, int d_b_pix_size)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	if (i < d_b_pix_size)
	{
		int px = i % width;
		int py = (i % (b_width * height)) / b_width;
		int ip = px + py * width;
		int mx = (i % b_width) / width;
		int my = i / (b_width * height);
		int im = mx + (4 - my) * 5;
		short p, m, sum;

		p = d_pix[ip].rgbtBlue;
		m = mask[im].blue;
		sum = p + m;
		if (sum >= 255)
			d_b_pix[i].rgbtBlue = 255;
		else if (sum < 0)
			d_b_pix[i].rgbtBlue = 0;
		else
			d_b_pix[i].rgbtBlue = sum;

		p = d_pix[ip].rgbtGreen;
		m = mask[im].green;
		sum = p + m;
		if (sum >= 255)
			d_b_pix[i].rgbtGreen = 255;
		else if (sum < 0)
			d_b_pix[i].rgbtGreen = 0;
		else
			d_b_pix[i].rgbtGreen = sum;

		p = d_pix[ip].rgbtRed;
		m = mask[im].red;
		sum = p + m;
		if (sum >= 255)
			d_b_pix[i].rgbtRed = 255;
		else if (sum < 0)
			d_b_pix[i].rgbtRed = 0;
		else
			d_b_pix[i].rgbtRed = sum;
	}
}

int main()
{
	GraphicInfo();
	MaskAlloc();
	//TIFF START
	FreeImage_Initialise(TRUE);
	TiffToBmp();
	MultiColor();
	BmpToTiff();
	//TIFF END
	FreeImage_DeInitialise();

	free(pix);
	free(b_pix);
	free(threadsPerBlock);
	for (int i = 0; i < device_count; i++)
	{
		free(device_name[i]);
	}
	free(device_name);

	system("pause");
	return 0;
}
void MultiColor()
{
	FILE * fp;
	fp = fopen("input.bmp", "rb");

	if (fp == NULL)
	{
		printf("File Not Found!!\n");
		system("pause");
		exit(0);
	}
	// 파일헤더, 정보헤더 읽어들인다
	fread(&bfh, sizeof(bfh), 1, fp);
	fread(&bih, sizeof(bih), 1, fp);

	width = bih.biWidth;
	height = bih.biHeight;
	b_width = width * channel;
	b_height = height * channel;


	// BPL을 맞춰주기 위해서 픽셀데이터의 메모리를 4의 배수로 조정
	bpl = (width * 3 + 3) / 4 * 4;
	b_bpl = (b_width * 3 + 3) / 4 * 4;

	// 패딩 값 계산
	pad = bpl - width * 3;
	b_pad = b_bpl - b_width * 3;

	// BPL을 맞춘 메모리 사이즈
	bpl_size = bpl * height;
	b_bpl_size = b_bpl * b_height;

	// 순수 이미지 사이즈
	pix_size = width * height;
	b_pix_size = b_width * b_height;

	printf("Image size : %d X %d\n", width, height);
	printf("Memory size : %d byte\n", bpl_size);
	printf("%d X %d Image size : %d X %d\n", channel, channel, b_width, b_height);
	printf("%d X %d Memory size : %d byte\n", channel, channel, b_bpl_size);

	// 원본 이미지 데이터 할당
	pix = (RGBTRIPLE *)calloc(pix_size, sizeof(RGBTRIPLE));
	for (int i = 0; i < height; i++)
	{
		fread(pix + (i * width), sizeof(RGBTRIPLE), width, fp);
		fread(&trash, sizeof(BYTE), pad, fp);
	}
	// 원본 이미지를 다 읽은 후 원본 파일은 닫는다.
	fclose(fp);
	// 5 X 5 이미지 데이터 할당
	b_pix = (RGBTRIPLE *)calloc(b_pix_size, sizeof(RGBTRIPLE));

	QueryPerformanceFrequency(&tot_clockFreq);	// 시간을 측정하기위한 준비

	QueryPerformanceCounter(&tot_beginClock); // GPU 시간측정 시작
	// Add vectors in parallel.
	cudaError_t cudaStatus = extendWithCuda(b_pix, threadsPerBlock[device_num]);
	QueryPerformanceCounter(&tot_endClock); // GPU 시간측정 종료
	total_Time_GPU = (double)(tot_endClock.QuadPart - tot_beginClock.QuadPart) / tot_clockFreq.QuadPart;

	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "extendWithCuda failed!\n");
		system("pause");
		exit(1);
	}

	// cudaDeviceReset must be called before exiting in order for profiling and
	// tracing tools such as Nsight and Visual Profiler to show complete traces.
	cudaStatus = cudaDeviceReset();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceReset failed!\n");
		system("pause");
		exit(1);
	}
	printf("실행시간 : %.1lf(Sec)\n", total_Time_GPU);

	sprintf(str_Extend, "output.bmp");
	Fwrite_Extend(str_Extend);
}
// Helper function for using CUDA to add vectors in parallel.
cudaError_t extendWithCuda(RGBTRIPLE* b_pix, int thread)
{
	RGBTRIPLE * d_b_pix = 0;
	RGBTRIPLE * d_pix = 0;
	MASK * mask = 0;
	cudaError_t cudaStatus;

	// Choose which GPU to run on, change this on a multi-GPU system.
	cudaStatus = cudaSetDevice(device_num);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaSetDevice failed!\n  Do you have a CUDA-capable GPU installed?\n");
		goto Error;
	}

	// Allocate GPU buffers for three vectors (two input, one output)    .
	cudaStatus = cudaMalloc((void**)&d_b_pix, b_pix_size * sizeof(RGBTRIPLE));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!\n");
		goto Error;
	}

	cudaStatus = cudaMalloc((void**)&d_pix, pix_size * sizeof(RGBTRIPLE));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!\n");
		goto Error;
	}

	cudaStatus = cudaMalloc((void**)&mask, 25 * sizeof(MASK));
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMalloc failed!\n");
		goto Error;
	}

	// Copy input vectors from host memory to GPU buffers.
	cudaStatus = cudaMemcpy(d_pix, pix, pix_size * sizeof(RGBTRIPLE), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!\n");
		goto Error;
	}

	cudaStatus = cudaMemcpy(mask, Mask, 25 * sizeof(MASK), cudaMemcpyHostToDevice);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!\n");
		goto Error;
	}

	// Launch a kernel on the GPU with one thread for each element.
	// 함수명<<<블록 수, 스레드 수>>>(매개변수);
	extendKernel << < (b_pix_size + thread - 1) / thread, thread >> > (d_b_pix, d_pix, mask, width, b_width, height, b_pix_size);

	// Check for any errors launching the kernel
	cudaStatus = cudaGetLastError();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "extendKernel launch failed: %s\n", cudaGetErrorString(cudaStatus));
		goto Error;
	}

	// cudaDeviceSynchronize waits for the kernel to finish, and returns
	// any errors encountered during the launch.
	cudaStatus = cudaDeviceSynchronize();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching addKernel!\n", cudaStatus);
		goto Error;
	}

	// Copy output vector from GPU buffer to host memory.
	cudaStatus = cudaMemcpy(b_pix, d_b_pix, b_pix_size * sizeof(RGBTRIPLE), cudaMemcpyDeviceToHost);
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "cudaMemcpy failed!\n");
		goto Error;
	}



Error:
	cudaFree(d_b_pix);
	cudaFree(d_pix);
	cudaFree(mask);

	return cudaStatus;
}
void TiffToBmp()
{
	FIBITMAP *ddib = FreeImage_Load(FIF_TIFF, "input.tif", TIFF_DEFAULT);
	if (ddib) {
		printf("TIFF successfully loaded!\n");
		/*
		w = FreeImage_GetWidth(ddib);
		h = FreeImage_GetHeight(ddib);
		d = FreeImage_GetBPP(ddib);
		sz = FreeImage_GetDIBSize(ddib);

		printf("width=%d, height=%d, depth=%d size=%d \n", w, h, d, sz);
		*/
		FIBITMAP *thumbnail = FreeImage_MakeThumbnail(ddib, THUMBNAIL_SIZE, TRUE);
		if (thumbnail) {
			FreeImage_Save(FIF_TIFF, thumbnail, "src_thumb.tif", TIFF_DEFAULT);
			FreeImage_Save(FIF_BMP, thumbnail, "src_thumb.bmp", BMP_DEFAULT);
			printf("Source thumbnail Images [tiff and bmp] Create!\n");
			FreeImage_Unload(thumbnail);
		}
		FreeImage_Save(FIF_BMP, ddib, "input.bmp", BMP_DEFAULT);
		printf("INPUT BMP Image Create\n");

		FreeImage_Unload(ddib);
	}
	else {
		printf("TIFF Image not found!\n");
		exit(0);
	}
}
void BmpToTiff()
{
	FIBITMAP *dib = FreeImage_Load(FIF_BMP, "output.bmp", BMP_DEFAULT);

	printf("TIFF FILE NAME IS %s\n", "output.tif");
	if (dib) {
		/*
		printf("BMP successfully loaded!\n");
		w = FreeImage_GetWidth(dib);
		h = FreeImage_GetHeight(dib);
		d = FreeImage_GetBPP(dib);
		sz = FreeImage_GetDIBSize(dib);
		printf("width=%d, height=%d, depth=%d size=%d \n", w, h, d, sz);
		*/
		FIBITMAP *thumbnail_multi = FreeImage_MakeThumbnail(dib, THUMBNAIL_SIZE, TRUE);
		if (thumbnail_multi) {
			FreeImage_Save(FIF_BMP, thumbnail_multi, "multi_thumb.bmp", BMP_DEFAULT);
			printf("Multi BMP thumbnail Image Create\n");
			FreeImage_Unload(thumbnail_multi);
		}
		FreeImage_Save(FIF_TIFF, dib, "output.tif", TIFF_DEFAULT);
		printf("TIFF Image Create\n");

		FreeImage_Unload(dib);
	}
}
void MaskAlloc()
{
	char c;
	FILE * fp;
	fp = fopen("config_5.txt", "r");
	if (fp == NULL)
	{
		printf("File Not Found!!\n");
		system("pause");
		return;
	}
	printf("\n");
	printf("--- 5 X 5 마스크 값 행렬 ---\n");
	for (int i = 0; i < 25; i++)
	{
		fscanf(fp, "%d%c", &Mask[i].red, &c);
		fscanf(fp, "%d%c", &Mask[i].green, &c);
		fscanf(fp, "%d%c", &Mask[i].blue, &c);
	}
	for (int i = 0; i < 5; i++)
	{
		for (int j = 0; j < 5; j++)
		{
			printf("%3d, %3d, %3d.  ", Mask[j + 5 * i].red, Mask[j + 5 * i].green, Mask[j + 5 * i].blue);
		}
		printf("\n");
		printf("\n");
	}
	printf("\n");

	fclose(fp);
}
void GraphicInfo()
{
	cudaDeviceProp  prop;

	int count;
	cudaGetDeviceCount(&count);
	device_count = count;
	threadsPerBlock = (int *)calloc(count, sizeof(int));
	device_name = (char **)calloc(count, sizeof(char*));


	for (int i = 0; i < count; i++) {
		device_name[i] = (char *)malloc(sizeof(char) * 256);
		cudaGetDeviceProperties(&prop, i);
		memcpy(device_name[i], prop.name, 256);
		threadsPerBlock[i] = prop.maxThreadsPerBlock;

		printf("   --- General Information for device %d ---\n", i);
		printf("Name:  %s\n", prop.name);
		printf("Compute capability:  %d.%d\n", prop.major, prop.minor);
		printf("Clock rate:  %d\n", prop.clockRate);
		printf("Device copy overlap:  ");
		if (prop.deviceOverlap)
			printf("Enabled\n");
		else
			printf("Disabled\n");
		printf("Kernel execution timeout :  ");
		if (prop.kernelExecTimeoutEnabled)
			printf("Enabled\n");
		else
			printf("Disabled\n");
		printf("\n");

		printf("   --- Memory Information for device %d ---\n", i);
		printf("Total global mem:  %ld\n", prop.totalGlobalMem);
		printf("Total constant Mem:  %ld\n", prop.totalConstMem);
		printf("Max mem pitch:  %ld\n", prop.memPitch);
		printf("Texture Alignment:  %ld\n", prop.textureAlignment);
		printf("\n");

		printf("   --- MP Information for device %d ---\n", i);
		printf("Multiprocessor count:  %d\n", prop.multiProcessorCount);
		printf("Shared mem per mp:  %ld\n", prop.sharedMemPerBlock);
		printf("Registers per mp:  %d\n", prop.regsPerBlock);
		printf("Threads in warp:  %d\n", prop.warpSize);
		printf("Max threads per block:  %d\n", prop.maxThreadsPerBlock);
		printf("Max thread dimensions:  (%d, %d, %d)\n", prop.maxThreadsDim[0], prop.maxThreadsDim[1], prop.maxThreadsDim[2]);
		printf("Max grid dimensions:  (%d, %d, %d)\n", prop.maxGridSize[0], prop.maxGridSize[1], prop.maxGridSize[2]);
		printf("--------------------------------------\n");
		printf("\n");
	}
	printf("device_list\n");
	for (int i = 0; i < device_count; i++)
	{
		printf("device%d : %s\n", i, device_name[i]);
	}
	printf("Please input device_num.\n");
	printf("device_num : ");
	scanf("%d", &device_num);
}

// 데이터 픽셀값을 bmp파일로 쓴다.
void Fwrite_Extend(char * fn)
{
	FILE * fp2 = fopen(fn, "wb");
	b_bfh = bfh;
	b_bih = bih;
	b_bih.biWidth = b_width;
	b_bih.biHeight = b_height;
	b_bih.biSizeImage = b_bpl_size;
	b_bfh.bfSize = b_bih.biSizeImage + sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);

	fwrite(&b_bfh, sizeof(bfh), 1, fp2);
	fwrite(&b_bih, sizeof(bih), 1, fp2);

	for (int i = 0; i < b_height; i++)
	{
		fwrite(b_pix + (i * b_width), sizeof(RGBTRIPLE), b_width, fp2);
		fwrite(&trash, sizeof(BYTE), b_pad, fp2);
	}

	fclose(fp2);
}
