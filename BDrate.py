import math
import pandas as pd
import bjontegaard as bd

def repairCurve(metricName, data):
    if metricName == "NAT_DISTS":
        data = [-x for x in data]
    cleanData = [data[0]]
    for i in range(1, len(data)):
        if data[i] > cleanData[i-1]:
            cleanData.append(data[i])
        else:
            cleanData.append(cleanData[i-1]+0.000001)
    return cleanData

data = pd.read_csv("data.csv")
metricsColumns = ["PSNR", "SSIM", "VMAF", "FSIM", "NAT_DISTS", "LIQE", "QUALICLIP", "ARNIQA"]
sizeColumn = "size"
codecColumn = "codec"
codecs = ["jxl", "jpegai", "vvc", "av1", "av2", "dcvc", "dcmvc", "glc"]
codecNames = ["JPEG XL", "JPEG AI", "VVC", "AV1", "AV2", "DCVC", "DCMVC", "GLC"]

for codecA in codecs:
    print("\\hline")
    print("\\textbf{"+ codecNames[codecs.index(codecA)] +"} &");
    for codecB in codecs:
        if codecA == codecB:
            result = "N/A"
        else:
            for metric in metricsColumns:
                codecAData = data.loc[data[codecColumn] == codecA, metric].tolist()
                codecASizes = data.loc[data[codecColumn] == codecA, sizeColumn].tolist()
                codecBData = data.loc[data[codecColumn] == codecB, metric].tolist()
                codecBSizes = data.loc[data[codecColumn] == codecB, sizeColumn].tolist()
                #print(codecA, codecB, metric)
                #print (codecASizes, codecAData, codecBSizes, codecBData)
                codecAData = repairCurve(metric, codecAData)
                codecBData = repairCurve(metric, codecBData)
                rate = bd.bd_rate(codecASizes, codecAData, codecBSizes, codecBData, method='akima', min_overlap=0.0)
                if math.isnan(rate):
                    rate = "-"
                else:
                    if len(str(int(abs(rate)))) < 3:
                        rate = f"{rate:.2f}"
                    else:
                        rate = f"{rate:.0f}"
                result += rate
                if metric != metricsColumns[-1]:
                    result += ", "
                if metricsColumns.index(metric) % 2 == 1:
                    result += " \\\\ "
        result = "\\makecell{" + result + "}"
        if(codecB == codecs[-1]):
            print(result+" \\\\")
        else:
            print(result+" &")
        result = ""
    print("")
