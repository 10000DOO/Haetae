# 로컬 LLM 후보 조사

> 작성: 2026-11-19, Claude 서브에이전트 조사 결과 원문 · 범위: 상업 이용 가능 라이선스, mlx-swift-lm 지원, 4bit 크기, 성능 근거
> 상위 문서: [../haetae-security-monitor.md](../haetae-security-monitor.md) · 이 파일은 참고 자료이며, 채택 여부는 상위 문서 3장·9장이 기준이다.

---

## 결론

1. **메모리 구간별 추천:** 16GB 미만은 `Qwen3.5-4B`(thinking 끄고 사용), 16~32GB는 `Nemotron 3.5 Bolt E4B` 또는 `Qwen3.5-9B`, 32GB 이상은 `Qwen3.8-27B` 또는 `Gemma 4 26B-A4B`입니다.
2. **한국어 근거:** 후보 중 한국어 점수가 공개된 것은 Gemma 4 계열과 SKT `A.X 4.0 Light`뿐입니다. 그래서 바꾸기 전에 앱 안에서 한국어 JSON 판정을 직접 비교해 봐야 합니다.
3. **Gemma 4 라이선스:** Gemma Terms of Use가 아니라 **Apache 2.0**입니다. 라이선스 사본과 고지만 지키면 상업 배포가 가능합니다.

## 후보 표

- 크기는 HF API `?blobs=true`로 받은 파일 크기 합계(실측)입니다. KV 캐시는 포함하지 않았습니다.
- "지원" 열은 `LLMModelFactory.swift`(3.33.0 태그, main과 동일)에 그 `model_type` 키가 있는지 대조한 결과입니다.

| 모델 | MLX repo id | 4bit 크기 | 라이선스 + 상업 이용 조건 | mlx-swift-lm 지원 | 성능 근거 | 한국어 | 추천 구간 |
|---|---|---|---|---|---|---|---|
| Gemma 4 E2B (현재 기본값) | `mlx-community/gemma-4-e2b-it-4bit` | 3.58GB | [Apache 2.0](https://ai.google.dev/gemma/docs/gemma_4_license), 상업 가능 | `gemma4` ✅ | MMLU-Pro 60.0, MMMLU 67.4 ([Google 카드](https://huggingface.co/google/gemma-4-E2B-it)) | Ko-IFEval 66.83 (KBS) | <16 |
| Gemma 4 E4B (현재 기본값) | `mlx-community/gemma-4-e4b-it-4bit` | 5.18GB | Apache 2.0 | `gemma4` ✅ | MMLU-Pro 69.4, Tau2 42.2 | Ko-IFEval 74.79 (KBS) | 16~32 |
| Gemma 4 12B (현재 기본값) | `mlx-community/gemma-4-12B-it-4bit` | 6.77GB | Apache 2.0 | `gemma4_unified` ✅ | MMLU-Pro 77.2, MMMLU 83.4 | 확인 못 함 | 32+ |
| **Gemma 4 26B-A4B** (MoE) | `mlx-community/gemma-4-26b-a4b-it-4bit` | 15.37GB | Apache 2.0 | `gemma4` ✅ (MoE 코드 있음) | MMLU-Pro 82.6, MMMLU 86.3 | **Ko-IFEval 80.50** (KBS) | 32+ |
| **Qwen3.5-4B** | `mlx-community/Qwen3.5-4B-MLX-4bit` | 3.06GB | [Apache 2.0](https://huggingface.co/Qwen/Qwen3.5-4B/blob/main/LICENSE) | `qwen3_5` ✅ | thinking 모드 점수: MMLU-Pro 79.1, IFEval 89.8, IFBench 59.2 ([Qwen 카드](https://huggingface.co/Qwen/Qwen3.5-4B)) | thinking 켜면 Ko-IFEval 20.93, 끄면 Ko-GSM8K 69.6 (KBS). thinking 끈 Ko-IFEval은 없음 | **<16** |
| **Qwen3.5-9B** | `mlx-community/Qwen3.5-9B-MLX-4bit` | 5.98GB | Apache 2.0 | `qwen3_5` ✅ | MMLU-Pro 82.5, IFEval 91.5, IFBench 64.5 | thinking 끄면 Ko-GSM8K 77.3 (KBS) | **16~32** |
| **Nemotron 3.5 Bolt E4B** (NVIDIA, 2026-10, Gemma 4 E4B 기반) | `lmstudio-community/NVIDIA-Nemotron-3.5-Bolt-E4B-MLX-4bit` | 4.23GB | [OpenMDW-1.1](https://openmdw.ai/license/1-1/)(사용 제한·상한 없음, 사본 유지 의무) + 베이스 Apache 2.0 | `gemma4` ✅ (config 구조가 Gemma4 E4B와 같음) | NVIDIA 카드, Gemma4 E4B 대비: **IHEval 84.8 vs 67.0**(지시 계층, 프롬프트 인젝션과 관련), StructEval-T 80.4 vs 79.3, IFBench 63.8 vs 42.8 | 언어 목록에 ko 있음, 점수는 확인 못 함 | **16~32** |
| **Qwen3.8-27B** | `mlx-community/Qwen3.8-27B-4bit` (`LLMRegistry`에 등록됨) | 16.07GB | Apache 2.0 | `qwen3_5` ✅ | IFBench 79.5, GPQA-D 89.2 ([Qwen 카드](https://huggingface.co/Qwen/Qwen3.8-27B)) | 확인 못 함 | **32+** |
| Qwen3.6-35B-A3B | `mlx-community/Qwen3.6-35B-A3B-4bit` | 20.43GB | Apache 2.0 | `qwen3_5_moe` ✅ | MMLU-Pro 85.2, GPQA 86.0 | 확인 못 함 | 48GB 이상 권장 (32GB에선 빠듯함, 추정) |
| gpt-oss-20b | `mlx-community/gpt-oss-20b-MXFP4-Q8` (`LLMRegistry` 등록) | 12.10GB | [Apache 2.0](https://huggingface.co/openai/gpt-oss-20b) + 법 준수만 요구하는 짧은 USAGE_POLICY | `gpt_oss` ✅ | MMLU-Pro 74.8, IFEval 88.2, MMMLU 69.7 (Qwen3.5 카드 비교표) | 확인 못 함 | 32+ |
| Ministral 3 3B / 8B / 14B | `mlx-community/Ministral-3-{3B,8B,14B}-Instruct-2512-4bit` | 2.78 / 5.63 / 8.46GB | [Apache 2.0](https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512) | `mistral3` ✅ | Arena Hard 8B 0.509, 14B 0.551 | 지원 언어에 한국어 있음, 점수 없음 | <16 / 16~32 |
| Granite 4.2 3B / 8B | `ibm-granite/granite-4.2-{3b,8b}-q4-mlx` (IBM 공식) | 2.07 / 4.95GB | [Apache 2.0](https://huggingface.co/ibm-granite/granite-4.2-8b) | `granite` ✅ | 8B: IFBench 79.3, MMLU-Pro 74.0, MMLU-ProX lite 61.1. 3B는 MMLU-ProX lite 27.8로 다국어가 약함 | 시험 언어에 ko 있음, 점수 없음 | 16~32 (8B) |
| GLM-4.7-Flash | `mlx-community/GLM-4.7-Flash-4bit` | 16.87GB | [MIT](https://huggingface.co/zai-org/GLM-4.7-Flash) | `glm4_moe_lite` ✅ | GPQA 75.2, τ²-Bench 79.5 | 확인 못 함 | 32+ |
| A.X 4.0 Light (SKT, Qwen2.5-7B 기반) | `meetLog/A.X-4.0-Light-mlx-4bit` (비공식 변환) | 4.09GB | [Apache 2.0](https://huggingface.co/skt/A.X-4.0-Light/blob/main/LICENSE) | `qwen2` ✅ | IFEval 84.68, MMLU 75.43 (SKT 카드) | **Ko-IFEval 73.72** (KBS), KMMLU 64.15 | 16~32 (한국어 우선일 때) |
| Foundation-Sec-1.1-8B-Instruct (Cisco 보안 특화) | `gjdeboer/Foundation-Sec-1.1-8B-Instruct-mlx-4Bit` (비공식 변환) | 4.53GB | [NOTICE.md](https://huggingface.co/fdtn-ai/Foundation-Sec-1.1-8B-Instruct/blob/main/NOTICE.md): [Llama 3.1 라이선스](https://www.llama.com/llama3_1/license/)를 이어받음. MAU 7억 초과 시 별도 허가, "Built with Llama" 표시, AUP 준수, 라이선스 사본 제공 | `llama` ✅ | CTI-MCQA 0.644, CTI-RCM 0.694, IFEval 0.815 (Cisco 카드) | 지원 언어가 English뿐. 베이스인 Llama-3.1-8B는 Ko-IFEval 60.1 (Mi:dm 카드) | 비추천 |
| Phi-4-mini | `mlx-community/Phi-4-mini-instruct-4bit` | 2.18GB | MIT | `phi3` ✅ | MMLU-Pro 52.8, Multilingual MMLU 49.3 | 점수 없음 | 비추천 (구세대) |

## 제외한 후보

| 후보 | 제외 이유 |
|---|---|
| Meta Muse Glimmer 30B | Apache 2.0이지만 `muse_glimmer` 키가 레지스트리에 없음 |
| Qwen3.8-Flash-Next | `qwen4_exp` 미지원, 4bit 111GB, Qwen Community License |
| GLM-5.3-Flash | `glm5_next` 미지원, 원본 328GB |
| Microsoft Aion-1.0 2.3B (2026-11-18 공개) | `aion_instruct` 미지원 |
| HyperCLOVA X SEED Think 14B | `hyperclovax` 미지원. 1.5B는 Ko-IFEval 22.24로 낮음 |
| ERNIE-4.5-21B-A3B | `ernie4_5_moe` 미지원 (레지스트리에는 `ernie4_5`만 있음) |
| EXAONE 4.0 | EXAONE License 1.2 - NC, 비상업 전용 |
| Kanana 2 | §4.1(iii): 온디바이스에 넣어 제3자에게 제공하면 별도 상업 라이선스 필요. "Powered by Kanana" 표시 의무도 있음 |
| LFM2.5 / LFM3 | LFM Open License v1.0: 연매출 1천만 달러 이상 기업은 상업 이용 불가 |
| Llama 3.1 / 3.2 | 라이선스상 상업 이용은 되지만 성능이 구세대 |
| Foundation-Sec-8B-Reasoning, Cisco antares-1b | Reasoning은 같은 Llama 라이선스에 추론형이라 느림. antares-1b는 수동 승인 gated에 취약점 탐지 전용 |
| Shieldstral 1.0 3B | 안전성 점수만 내는 분류기라 판정 이유를 생성하지 못함 |
| MiMo-V2.6-Distill-Qwen-9B | 연구 출발점용 SFT 체크포인트, MLX는 OptiQ 혼합 양자화만 있음 |
| FrogNano-4B | 코딩 에이전트 전용 |
| SmolLM3 | 한국어 미지원 |
| DeepSeek-R1 증류 모델 | 항상 추론 모드라 짧은 판정에 느림 |
| Nemotron 3.5 Lightning | 언어 목록에 한국어 없음 |
| Mi:dm 2.0 Mini | MLX 4bit 변환본이 없고 Ko-IFEval 53.98 |
| Olmo 3, Apertus, Trinity Nano, Jamba 3B | 라이선스와 지원은 문제없으나 한국어 근거가 없음 |

## 확인한 것과 확인 못 한 것

**확인한 것**
- **Gemma 4 라이선스:** 원본 `google/gemma-4-*` 카드가 모두 `license: apache-2.0`입니다. 라이선스 링크는 Apache 2.0 원문 페이지로 연결되고 추가 조항은 없습니다.
- **MLX 변환본 메타데이터 오류:** mlx-community 변환본은 `license: gemma`(E2B/E4B)로 잘못 표기돼 있고, 12B는 라이선스 표기가 아예 없습니다. 배포할 때는 원본 기준(Apache 2.0)으로 고지하면 됩니다.
- **thinking 끄는 경로:** Qwen3.5와 Granite 4.2는 기본이 thinking 모드입니다. 끄려면 `UserInput.additionalContext`로 `enable_thinking: false`를 넘기는 경로가 코드에 있습니다.
- **JSON 강제 기능:** 3.33.0에 `MLXGuidedGeneration`(xgrammar 기반 JSON 강제 생성) 라이브러리가 있습니다. 모델을 바꿔도 D10의 JSON 형식 안정성에 도움이 됩니다.
- **최소 macOS 버전:** 패키지 최소 버전은 macOS 14입니다. 브리프의 15와 다르지만, 앱 타깃이 15라면 문제없습니다.
- **한국어 수치 원문 대조:** KBS 논문(서울대, [arXiv 2610.21227](https://arxiv.org/html/2610.21227)) Table 14·15 HTML 원문에서 직접 대조했습니다.

**확인 못 한 것**
- 어떤 후보도 mlx-swift-lm에서 실제로 로드하거나 생성해 보지 않았습니다. 특히 Bolt 같은 비공식 변환본과 Qwen3.5 VLM 가중치가 정상 로드되는지는 확인이 필요합니다.
- KV 캐시를 포함한 실제 메모리 사용량과 생성 속도는 측정하지 않았습니다.
- Qwen3.5를 thinking 끄고 돌렸을 때의 Ko-IFEval, 그리고 Qwen3.6·3.8, Bolt, gpt-oss, Ministral, Granite, GLM의 한국어 점수는 찾지 못했습니다.
- gemma.ai 사이드바에 따로 있는 "Prohibited use" 페이지가 Gemma 4에도 적용되는지는 확인하지 못했습니다. 라이선스 본문에는 그런 조항이 없습니다.
- 벤치마크는 대부분 제조사가 직접 발표한 수치입니다.

라이선스 판단은 법률 검토가 아닙니다. 상업 배포 전에 법무 확인을 권합니다.

출처: [Gemma 4 Apache 2.0 (The Decoder)](https://the-decoder.com/googles-gemma-4-is-now-available-with-apache-2-0-licensing-for-the-first-time/), [VentureBeat](https://venturebeat.com/technology/google-releases-gemma-4-under-apache-2-0-and-that-license-change-may-matter), [Nemotron 3.5 Bolt (NVIDIA Research)](https://research.nvidia.com/labs/nemotron/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB/), [Muse Glimmer (VentureBeat)](https://venturebeat.com/technology/meta-returns-to-open-source-with-muse-glimmer-an-apache-2-0-licensed-30b-parameter-ai-model-optimized-for-agents-available-now), [LFM3 라이선스 (MarkTechPost)](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/), [Foundation-sec-8B-Reasoning (Cisco)](https://blogs.cisco.com/security/foundation-sec-8b-reasoning-first-open-weight-security-reasoning-model), [Best Open Source LLMs Nov 2026 (Morph)](https://www.morphllm.com/best-open-source-llm), [KBS 논문](https://arxiv.org/html/2610.21227), [Kanana License](https://huggingface.co/kakaocorp/kanana-2-3b-instruct/blob/main/LICENSE), [EXAONE License](https://huggingface.co/LGAI-EXAONE/EXAONE-4.0-1.2B/blob/main/LICENSE), [LFM License](https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-4bit/blob/main/LICENSE)
