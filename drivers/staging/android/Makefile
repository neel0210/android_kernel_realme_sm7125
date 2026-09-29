ccflags-y += -I$(src)			# needed for trace events

obj-y					+= ion/

obj-$(CONFIG_ASHMEM)			+= ashmem.o
obj-$(CONFIG_ANDROID_VSOC)		+= vsoc.o
obj-$(CONFIG_ANDROID_LOW_MEMORY_KILLER)	+= lowmemorykiller.o

#ifdef OPLUS_FEATURE_HANS_FREEZE
#Kun.Zhou@ANDROID.RESCONTROL, 2019/09/23, add for hans freeze manager
obj-$(CONFIG_OPPO_HANS) += hans.o
obj-$(CONFIG_OPPO_HANS) += hans_netfilter.o
#endif /*OPLUS_FEATURE_HANS_FREEZE*/
lmk_tng-y := lowmemorykiller_tng.o lowmemorykiller_tasks.o \
             lowmemorykiller_oom.o lowmemorykiller_vmpressure.o
obj-$(CONFIG_ANDROID_LOW_MEMORY_KILLER_TNG) += lmk_tng.o
obj-$(CONFIG_ANDROID_LOW_MEMORY_KILLER_STATS) += lowmemorykiller_stats.o
