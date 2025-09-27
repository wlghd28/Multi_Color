#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <windows.h>
#include <time.h>
#include <process.h>
#include "deviceInfo.h"
#include "FreeImage.h"

#define THUMBNAIL_SIZE 400

// 마스크값 배열
short mask[75];

double total_Time_GPU = 0;
LARGE_INTEGER beginClock, endClock, clockFreq;
LARGE_INTEGER tot_beginClock, tot_endClock, tot_clockFreq;

unsigned char* pix;
unsigned char* b_pix;

BITMAPFILEHEADER bfh;
BITMAPINFOHEADER bih;
BITMAPFILEHEADER b_bfh;
BITMAPINFOHEADER b_bih;


// 이미지 정보를 다루기 위해 사용하는 변수
int channel = 5;
int bpl, b_bpl;
int bpl_size, b_bpl_size;
int width, height, b_width, b_height;
int m_width, b_m_width;
int pix_size;
int b_pix_size;	// 5 X 5개 만큼 복붙한 이미지 사이즈
int pad, b_pad;		// 패딩 메모리 사이즈
BYTE trash[3] = { 0 };		// 패딩 메모리


void TiffToBmp();			// tiff파일을 bmp파일로 변환하는 작업
void BmpToTiff();			// bmp파일을 tiff파일로 변환하는 작업
void MaskAlloc();			// 마스크 값 할당
char str_Extend[100];
void Fwrite_Extend(char * fn);		// 연산된 픽셀값을 bmp파일로 저장한다
void MultiColor();			// 멀티칼라 연산

// OpenCL 관련 함수
char* readSource(char* kernelPath);
void CLInit();
void bufferWrite();
void runKernel();
void Release();

// main
int main(int argc, char** argv) {
	// OpenCL 디바이스, 커널 셋업
	CLInit();
	MaskAlloc();
	//TIFF START
	FreeImage_Initialise(TRUE);
	TiffToBmp();
	MultiColor();
	BmpToTiff();
	//TIFF END
	FreeImage_DeInitialise();
	Release();
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

	// 순수 이미지 메모리 사이즈
	pix_size = width * height * 3;
	b_pix_size = b_width * b_height * 3;

	printf("Image size : %d X %d\n", width, height);
	printf("Memory size : %d byte\n", bpl_size);
	printf("%d X %d Image size : %d X %d\n", channel, channel, b_width, b_height);
	printf("%d X %d Memory size : %d byte\n", channel, channel, b_bpl_size);

	// 24비트 rgb bmp파일은 한픽셀당 3byte 이므로 3씩 곱해준다
	m_width = width * 3;
	b_m_width = b_width * 3;

	// 원본 이미지 데이터 할당
	pix = (unsigned char *)calloc(pix_size, sizeof(unsigned char));
	for (int i = 0; i < height; i++)
	{
		fread(pix + (i * m_width), sizeof(unsigned char), m_width, fp);
		fread(&trash, sizeof(BYTE), pad, fp);
	}
	// 원본 이미지를 다 읽은 후 원본 파일은 닫는다.
	fclose(fp);

	// 5 X 5 이미지 데이터 할당
	b_pix = (unsigned char *)calloc(b_pix_size, sizeof(unsigned char));

	QueryPerformanceFrequency(&tot_clockFreq);	// 시간을 측정하기위한 준비
	QueryPerformanceCounter(&tot_beginClock); // GPU 시간측정 시작
	// 디바이스 쪽 버퍼 생성 및 write								 
	bufferWrite();
	//커널 실행
	runKernel();
	QueryPerformanceCounter(&tot_endClock); // GPU 시간측정 종료

	total_Time_GPU = (double)(tot_endClock.QuadPart - tot_beginClock.QuadPart) / tot_clockFreq.QuadPart;
	printf("실행시간 : %.1lf(Sec)\n", total_Time_GPU);

	sprintf(str_Extend, "output.bmp");

	Fwrite_Extend(str_Extend);

	free(b_pix);
	free(pix);
	
}
void MaskAlloc()
{
	char c;
	FILE * fp;
	fp = fopen("config_5.txt", "r");
	printf("\n");
	printf("--- 5 X 5 마스크 값 행렬 ---\n");
	for (int i = 0; i < 75; i++)
	{
		fscanf(fp, "%d%c", &mask[i], &c);
	}
	for (int i = 0; i < 5; i++)
	{
		for (int j = 0; j < 15; j++)
		{
			printf("%3d. ", mask[j]);
		}
		printf("\n");
		printf("\n");
	}
	printf("\n");

	for (int i = 0; i < 75; i += 3)
	{
		c = mask[i + 2];
		mask[i + 2] = mask[i];
		mask[i] = c;
	}

	fclose(fp);
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
		fwrite(b_pix + (i * b_m_width), sizeof(unsigned char), b_m_width, fp2);
		fwrite(&trash, sizeof(BYTE), b_pad, fp2);
	}
	fclose(fp2);
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
// kernel을 읽어서 char pointer생성
char* readSource(char* kernelPath) {

	cl_int status;
	FILE *fp;
	char *source;
	long int size;

	printf("Program file is: %s\n", kernelPath);

	fp = fopen(kernelPath, "rb");
	if (!fp) {
		printf("Could not open kernel file\n");
		exit(-1);
	}
	status = fseek(fp, 0, SEEK_END);
	if (status != 0) {
		printf("Error seeking to end of file\n");
		exit(-1);
	}
	size = ftell(fp);
	if (size < 0) {
		printf("Error getting file position\n");
		exit(-1);
	}

	rewind(fp);

	source = (char *)malloc(size + 1);

	int i;
	for (i = 0; i < size + 1; i++) {
		source[i] = '\0';
	}

	if (source == NULL) {
		printf("Error allocating space for the kernel source\n");
		exit(-1);
	}

	fread(source, 1, size, fp);
	source[size] = '\0';

	return source;
}

//디바이스 init, 커널 생성
void CLInit()
{
	int i, j;
	char * value;
	size_t valueSize;
	cl_uint platformCount;
	cl_platform_id * platforms;
	cl_uint deviceCount;
	cl_device_id * devices;
	cl_uint maxComputeUnits;

	// get all platforms
	clGetPlatformIDs(0, NULL, &platformCount);
	platforms = (cl_platform_id *)malloc(sizeof(cl_platform_id) * platformCount);
	clGetPlatformIDs(platformCount, platforms, NULL);

	for (i = 0; i < platformCount; i++) {

		// get all devices
		clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, 0, NULL, &deviceCount);
		devices = (cl_device_id *)malloc(sizeof(cl_device_id) * deviceCount);
		clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, deviceCount, devices, NULL);

		// for each device print critical attributes
		for (j = 0; j < deviceCount; j++) {

			// print device name
			clGetDeviceInfo(devices[j], CL_DEVICE_NAME, 0, NULL, &valueSize);
			value = (char *)malloc(valueSize);
			clGetDeviceInfo(devices[j], CL_DEVICE_NAME, valueSize, value, NULL);
			printf("platform %d. Device %d: %s\n", i + 1, j + 1, value);
			free(value);

			// print hardware device version
			clGetDeviceInfo(devices[j], CL_DEVICE_VERSION, 0, NULL, &valueSize);
			value = (char *)malloc(valueSize);
			clGetDeviceInfo(devices[j], CL_DEVICE_VERSION, valueSize, value, NULL);
			printf(" %d.%d Hardware version: %s\n", i + 1, 1, value);
			free(value);

			// print software driver version
			clGetDeviceInfo(devices[j], CL_DRIVER_VERSION, 0, NULL, &valueSize);
			value = (char *)malloc(valueSize);
			clGetDeviceInfo(devices[j], CL_DRIVER_VERSION, valueSize, value, NULL);
			printf(" %d.%d Software version: %s\n", i + 1, 2, value);
			free(value);

			// print c version supported by compiler for device
			clGetDeviceInfo(devices[j], CL_DEVICE_OPENCL_C_VERSION, 0, NULL, &valueSize);
			value = (char*)malloc(valueSize);
			clGetDeviceInfo(devices[j], CL_DEVICE_OPENCL_C_VERSION, valueSize, value, NULL);
			printf(" %d.%d OpenCL C version: %s\n", i + 1, 3, value);
			free(value);

			// print parallel compute units
			clGetDeviceInfo(devices[j], CL_DEVICE_MAX_COMPUTE_UNITS,
				sizeof(maxComputeUnits), &maxComputeUnits, NULL);
			printf(" %d.%d Parallel compute units: %d\n", i + 1, 4, maxComputeUnits);
		}
	}
	int platformNum;
	int deviceNum;
	printf("\n\nSELECT PLATFORM('1' ~ '%d') : ", platformCount);
	scanf("%d", &platformNum);
	printf("\n");
	printf("SELECT DEVICE('1' ~ '%d') : ", deviceCount);
	scanf("%d", &deviceNum);
	printf("\n");
	clGetDeviceIDs(platforms[platformNum - 1], CL_DEVICE_TYPE_ALL, deviceCount, devices, NULL);

	device = devices[deviceNum - 1];

	//create context
	context = clCreateContext(NULL, 1, &device, NULL, NULL, NULL);

	//create command queue
	queue = clCreateCommandQueue(context, device, 0, NULL);

	// 텍스트파일로부터 프로그램 읽기
	char * source = readSource("kernel.cl");

	// compile program
	program = clCreateProgramWithSource(context, 1,
		(const char **)&source, NULL, NULL);
	cl_int build_status;
	build_status = clBuildProgram(program, 1, &device, NULL, NULL,
		NULL);

	//커널 포인터 생성
	simpleKernel = clCreateKernel(program, "simpleKernel", NULL);

}

//버퍼생성 및 write
void bufferWrite()
{
	// 메모리 버퍼 생성
	d_pix = clCreateBuffer(context, CL_MEM_READ_ONLY,
		pix_size * sizeof(unsigned char), NULL, NULL);
	d_b_pix = clCreateBuffer(context, CL_MEM_WRITE_ONLY,
		b_pix_size * sizeof(unsigned char), NULL, NULL);
	d_mask = clCreateBuffer(context, CL_MEM_READ_ONLY,
		75 * sizeof(short), NULL, NULL);

	clEnqueueWriteBuffer(queue, d_pix, CL_TRUE, 0, sizeof(unsigned char) * pix_size,
		pix, 0, NULL, NULL);
	clEnqueueWriteBuffer(queue, d_mask, CL_TRUE, 0, sizeof(short) * 75,
		mask, 0, NULL, NULL);

}

void runKernel()
{
	int totalWorkItemsX = b_pix_size;
	int totalWorkItemsY = 1;

	size_t globalSize[2] = { totalWorkItemsX, totalWorkItemsY };
	//float *minVal, *maxVal;

	// 커널 매개변수 설정 
	clSetKernelArg(simpleKernel, 0, sizeof(cl_mem), &d_pix);
	clSetKernelArg(simpleKernel, 1, sizeof(cl_mem), &d_b_pix);
	clSetKernelArg(simpleKernel, 2, sizeof(cl_mem), &d_mask);
	clSetKernelArg(simpleKernel, 3, sizeof(int), &m_width);
	clSetKernelArg(simpleKernel, 4, sizeof(int), &b_m_width);
	clSetKernelArg(simpleKernel, 5, sizeof(int), &height);

	clEnqueueNDRangeKernel(queue, simpleKernel, 2, NULL, globalSize,
		NULL, 0, NULL, NULL);
	// 완료 대기 
	clFinish(queue);

	clEnqueueReadBuffer(queue, d_b_pix, CL_TRUE, 0,
		b_pix_size * sizeof(unsigned char), b_pix, 0, NULL, NULL);

}
void Release()
{
	// 릴리즈
	clReleaseProgram(program);
	clReleaseCommandQueue(queue);
	clReleaseContext(context);
}