import pandas as pd

data = pd.read_csv("data.csv")
pointSize = 200000

metricsColumns = ["PSNR", "SSIM", "VMAF", "FSIM", "NAT_DISTS", "LIQE", "QUALICLIP", "ARNIQA"]
sizeColumn = "size"
codecColumn = "codec"
codecs = ["jxl", "jpegai", "vvc", "av1", "av2", "dcvc", "dcmvc", "glc"]
codecNames = ["JPEG XL", "JPEG AI", "VVC", "AV1", "AV2", "DCVC", "DCMVC", "GLC"]

for metric in metricsColumns:
    qualities = []
    validCodecs = []
    for codec in codecs:
        codecSizes = data.loc[data[codecColumn] == codec, sizeColumn].tolist()
        codecData = data.loc[data[codecColumn] == codec, metric].tolist()
        upperSize = float('inf')
        upperQuality = 0
        lowerSize = float('-inf')
        lowerQuality = 0
        for i in range(len(codecData)):
            size = codecSizes[i]
            if size > pointSize:
                if(size < upperSize):
                    upperQuality = codecData[i]
                    upperSize = size
            else:
                if(size > lowerSize):
                    lowerQuality = codecData[i]
                    lowerSize = size
        if upperSize == float('inf') or lowerSize == float('-inf'):
            print("The requested size is not available in the data of", codec, "for", metric)
            continue
        interpolatedQuality = (pointSize - lowerSize) / (upperSize - lowerSize) * (upperQuality - lowerQuality) + lowerQuality
        qualities.append(interpolatedQuality)
        validCodecs.append(codec)
    reverse = True
    if metric == "NAT_DISTS":
        reverse = False
    sortedIDs = [qualities.index(x) for x in sorted(qualities, reverse=reverse)]
    print(metric)
    for i in sortedIDs:
        print(validCodecs[i], qualities[i])
